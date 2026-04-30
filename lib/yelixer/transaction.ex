defmodule Yelixer.Transaction do
  @moduledoc """
  Aspirational batched-mutation API. Currently a partial / vestigial
  module — flagged for removal or completion.

  ## Honest current state

  This module ships with one mutator (`insert/4`) and one batch
  primitive (`transact/2`). The struct's `before_state` and
  `delete_set` fields suggest the intended shape was a classic CRDT
  transaction: capture the doc's state vector at the start, collect
  mutations into a deferred set, accumulate tombstones into a
  per-transaction delete set, and commit them all atomically as a
  single Yjs update. Most of that scaffolding is missing.

  Today the module supports:

    - `transact(doc, fun)` — wrap `fun` with a transaction context;
      `fun` receives a `%Transaction{}` and must return
      `{txn, result}`. Commit merges the txn's delete set into the
      doc and returns `{result, doc}`.
    - `insert(txn, parent, parent_sub, content)` — push one Item
      into the txn's underlying doc with `nil` anchors. No YATA
      integration, no broadcast, no run-length, no support for
      anchored inserts. Lower-level than the type facades.

  Today the module does **not** support:

    - Deletion. The `delete_set` field exists on the struct but no
      function adds to it. `commit/1` merges it dutifully — into a
      delete set that's always empty.
    - Type-aware operations. There's no `transact_text_insert`,
      `transact_array_push`, etc. The single `insert/4` lets callers
      drop raw Items but doesn't wire them through
      `Yelixer.Integrate.integrate/3`, so concurrent-insert
      ordering won't follow YATA.
    - Rollback. A `fun` that crashes mid-transaction leaves the
      caller without a recovery path; `transact/2` returns the
      partially-mutated doc only on the success path.
    - Anchored inserts. `insert/4` always passes `nil` for `origin`
      and `right_origin`, so transaction-built items can't position
      themselves relative to existing content.

  ## How callers get transaction-like semantics today

  They don't need this module. The type facades — `Yelixer.Types.Text`,
  `Array`, `YMap`, the XML modules — already return fresh `%Doc{}`
  values from each operation, giving callers copy-on-write semantics
  for free:

      doc =
        doc
        |> Text.insert("body", 0, "Hello")
        |> Array.push("items", [1, 2, 3])
        |> YMap.set("meta", "title", "Doc 1")

  Each step builds on the previous one without committing intermediate
  results to anything observable. If a caller wants "all of these
  mutations as one network message," they can run the whole pipeline
  locally and then call `Yelixer.Encoding.encode_diff/2` against the
  receiver's state vector — the diff naturally batches every change
  since the receiver's last sync.

  Mutations on a `Yelixer.DocServer` are even simpler: each mutation
  GenServer call is already serialized, and the broadcast-on-update
  loop sends one diff per mutation. Multi-step "atomic" semantics
  there mean composing the calls in the caller; there's no in-server
  transaction primitive needed for the existing use cases.

  ## What completion would look like

  If we ever revive this module, the shape that does match Yjs's wire
  contract is roughly:

    - All mutators run against the txn's accumulated state, threading
      through `Integrate.integrate/3` so YATA holds.
    - Deletes go into the per-txn `delete_set` and get merged at
      commit; they don't appear in `doc.delete_set` mid-transaction.
    - On commit, encode the txn's accumulated diff against
      `before_state` for fan-out — this is what makes "many edits
      = one network round" meaningful.
    - On crash mid-transaction, the original doc is unchanged because
      the txn worked on a copy.

  The yrs equivalent (`yrs::Transaction`) implements roughly that
  shape and is worth referencing if anyone takes this on.

  ## Recommendation

  Either complete it (filling in the gaps above) or remove it. Half-
  done public API surfaces are confusing for new contributors who try
  to use this module and discover the mismatch between the struct's
  shape and its actual capability. Filed for follow-up; commonplace
  side has the call.

  ## What this module is NOT (today)

  - Not a YATA-aware mutation API — `insert/4` skips
    `Yelixer.Integrate.integrate/3`.
  - Not the deletion path — `Yelixer.Types.YMap.delete/3`,
    `Array.delete/4`, etc. are the canonical paths.
  - Not the broadcast path — see `Yelixer.DocServer`.
  - Not the encoding layer — see `Yelixer.Encoding`.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, DeleteSet, StateVector}

  @type t :: %__MODULE__{
          doc: Doc.t(),
          before_state: StateVector.t(),
          delete_set: DeleteSet.t()
        }

  defstruct [:doc, :before_state, :delete_set]

  @doc """
  Runs `fun` inside a transaction context. `fun` receives a
  `%Transaction{}` and must return `{txn, result}`; the transaction
  commits and `{result, doc}` is returned to the caller.

  In its current form, `commit/1` only merges the txn's accumulated
  delete set into the doc — and nothing in this module adds anything
  to that delete set, so the merge is always a no-op. See the
  moduledoc for the full picture of what this primitive does and
  doesn't do today.
  """
  def transact(%Doc{} = doc, fun) when is_function(fun, 1) do
    txn = %__MODULE__{
      doc: doc,
      before_state: BlockStore.state_vector(doc.store),
      delete_set: DeleteSet.new()
    }

    {txn, result} = fun.(txn)
    doc = commit(txn)
    {result, doc}
  end

  @doc """
  Pushes one Item directly into the txn's doc store with `nil`
  anchors and no YATA integration. Lower-level than the type facades;
  not suitable for collaborative edits because concurrent inserts
  built this way won't agree on order across replicas.

  Use `Yelixer.Types.Text.insert/4` /
  `Yelixer.Types.Array.insert/4` / `Yelixer.Types.YMap.set/4` for
  YATA-correct mutations.
  """
  def insert(%__MODULE__{doc: doc} = txn, parent, parent_sub, content) do
    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, nil, nil, content, parent, parent_sub)
    store = BlockStore.push(doc.store, item)
    %{txn | doc: %{doc | store: store}}
  end

  defp commit(%__MODULE__{doc: doc, delete_set: ds}) do
    %{doc | delete_set: DeleteSet.merge(doc.delete_set, ds)}
  end
end
