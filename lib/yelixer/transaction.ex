defmodule Yelixer.Transaction do
  @moduledoc """
  Aspirational batched-mutation API. Partial and possibly vestigial —
  flagged for completion or removal.

  ## Current state

  Two functions exist: `transact/2` and `insert/4`. The struct's
  `before_state` and `delete_set` fields hint at the intended design —
  capture the doc's state vector at open, accumulate mutations and
  tombstones, commit everything as one Yjs update. That design is
  incomplete. Most of the scaffolding is missing.

  What works:

    - `transact(doc, fun)` — opens a transaction context, passes a
      `%Transaction{}` to `fun`, expects `{txn, result}` back, then
      commits. Commit merges the txn's delete set into the doc and
      returns `{result, doc}`.
    - `insert(txn, parent, parent_sub, content)` — appends one raw
      Item to the txn's doc store with `nil` anchors. No YATA
      integration. Lower-level than the type facades.

  What doesn't work:

    - **Deletion.** `delete_set` exists on the struct but nothing
      populates it. `commit/1` merges it anyway — always a no-op.
    - **Type-aware ops.** No `transact_text_insert`,
      `transact_array_push`, etc. `insert/4` bypasses
      `Yelixer.Integrate.integrate/3`, so items built here won't
      follow YATA ordering under concurrent edits.
    - **Rollback.** A crash mid-transaction leaves the caller holding
      a partially-mutated doc. `transact/2` has no recovery path.
    - **Anchored inserts.** `insert/4` always passes `nil` for
      `origin` and `right_origin`; items can't position themselves
      relative to existing content.

  ## How callers get transaction-like semantics today

  They bypass this module entirely. The type facades —
  `Yelixer.Types.Text`, `Array`, `YMap`, the XML modules — return a
  fresh `%Doc{}` from every operation, giving copy-on-write semantics
  for free:

      doc =
        doc
        |> Text.insert("body", 0, "Hello")
        |> Array.push("items", [1, 2, 3])
        |> YMap.set("meta", "title", "Doc 1")

  Each step threads forward without touching anything observable.
  For "batch these as one network message": run the pipeline locally,
  then call `Yelixer.Encoding.encode_diff/2` against the receiver's
  state vector — the diff batches every change since the last sync.

  `Yelixer.DocServer` is simpler still: GenServer calls are already
  serialized; broadcast-on-update fires once per mutation. "Atomic
  multi-step" just means composing calls in the caller — no in-server
  transaction primitive is needed.

  ## What completion would require

    - All mutators run against the txn's accumulated state, threaded
      through `Integrate.integrate/3` so YATA holds.
    - Deletes accumulate in the per-txn `delete_set` and merge at
      commit; they stay invisible in `doc.delete_set` mid-transaction.
    - On commit, encode the diff against `before_state` for fan-out —
      that's what makes "many edits, one network round" real.
    - On crash, the original doc is untouched because the txn worked
      on a copy.

  `yrs::Transaction` implements roughly this shape and is the right
  reference if anyone picks this up.

  ## Recommendation

  Complete it or delete it. A half-done public API misleads
  contributors who find the struct's shape and assume the semantics
  are there. Filed for follow-up; commonplace side has the call.

  ## What this module is NOT (today)

  - Not a YATA-aware mutation API — `insert/4` skips
    `Yelixer.Integrate.integrate/3`.
  - Not the deletion path — `Yelixer.Types.YMap.delete/3`,
    `Array.delete/4`, etc. are canonical.
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
  `%Transaction{}` and must return `{txn, result}`. On return,
  the transaction commits and `{result, doc}` goes back to the caller.

  `commit/1` merges the txn's delete set into the doc. Nothing in
  this module adds to that delete set, so the merge is always a
  no-op. See the moduledoc for the full accounting of what this
  primitive does and doesn't do.
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
  Appends one raw Item to the txn's doc store with `nil` anchors and
  no YATA integration. Lower-level than the type facades. Not safe
  for collaborative edits — concurrent inserts built this way won't
  converge to the same order across replicas.

  For YATA-correct mutations use `Yelixer.Types.Text.insert/4`,
  `Yelixer.Types.Array.insert/4`, or `Yelixer.Types.YMap.set/4`.
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
