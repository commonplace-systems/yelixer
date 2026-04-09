defmodule Yelixer.ItemTest do
  use ExUnit.Case, async: true

  alias Yelixer.{ID, Item}

  test "creates an item with string content" do
    item = Item.new(ID.new(1, 0), nil, nil, {:string, "hello"}, {:named, "text"}, nil)
    assert item.id == ID.new(1, 0)
    assert item.content == {:string, "hello"}
    assert item.length == 5
    assert item.deleted == false
  end

  test "string content length is character count" do
    item = Item.new(ID.new(1, 0), nil, nil, {:string, "abc"}, {:named, "text"}, nil)
    assert item.length == 3
  end

  test "deleted content has its stored length" do
    item = Item.new(ID.new(1, 0), nil, nil, {:deleted, 4}, {:named, "text"}, nil)
    assert item.length == 4
    assert item.deleted == true
  end

  test "any content length is element count" do
    item = Item.new(ID.new(1, 0), nil, nil, {:any, [1, "two", 3.0]}, {:named, "arr"}, nil)
    assert item.length == 3
  end

  test "single-value content types have length 1" do
    for content <- [{:embed, %{"img" => "url"}}, {:format, {"bold", true}}, {:type, :array}] do
      item = Item.new(ID.new(1, 0), nil, nil, content, {:named, "x"}, nil)
      assert item.length == 1
    end
  end

  test "binary content length is byte size" do
    item = Item.new(ID.new(1, 0), nil, nil, {:binary, <<1, 2, 3, 4>>}, {:named, "x"}, nil)
    assert item.length == 4
  end

  test "preserves origin and right_origin" do
    item =
      Item.new(
        ID.new(1, 5),
        ID.new(1, 3),
        ID.new(2, 0),
        {:string, "x"},
        {:named, "text"},
        nil
      )

    assert item.origin == ID.new(1, 3)
    assert item.right_origin == ID.new(2, 0)
  end

  test "preserves parent_sub for map entries" do
    item = Item.new(ID.new(1, 0), nil, nil, {:any, [42]}, {:named, "map"}, "key")
    assert item.parent_sub == "key"
  end

  describe "split/2" do
    test "splits string item at offset" do
      item = Item.new(ID.new(1, 0), nil, ID.new(2, 0), {:string, "hello"}, {:named, "text"}, nil)
      {left, right} = Item.split(item, 2)

      assert left.id == ID.new(1, 0)
      assert left.content == {:string, "he"}
      assert left.length == 2
      assert left.origin == nil
      # yrs behavior: left keeps the original's right_origin. The previous
      # implementation incorrectly set left.right_origin to right.id, which
      # broke parent resolution on rehydrate-then-modify cycles (CX-2sv).
      assert left.right_origin == ID.new(2, 0)

      assert right.id == ID.new(1, 2)
      assert right.content == {:string, "llo"}
      assert right.length == 3
      assert right.origin == ID.new(1, 1)
      assert right.right_origin == ID.new(2, 0)
    end

    test "splits leftmost item (no neighbors) keeps origin and right_origin nil" do
      # Regression test for CX-2sv: when the item being split was inserted
      # alone (origin=nil, right_origin=nil), the left half must keep both
      # nil so that on encode its parent is written explicitly.
      item = Item.new(ID.new(1, 0), nil, nil, {:string, "hello"}, {:named, "text"}, nil)
      {left, right} = Item.split(item, 1)

      assert left.origin == nil
      assert left.right_origin == nil

      assert right.id == ID.new(1, 1)
      assert right.origin == ID.new(1, 0)
      assert right.right_origin == nil
    end

    test "splits any content at offset" do
      item = Item.new(ID.new(1, 0), nil, nil, {:any, [1, 2, 3, 4]}, {:named, "arr"}, nil)
      {left, right} = Item.split(item, 2)

      assert left.content == {:any, [1, 2]}
      assert left.length == 2
      assert right.content == {:any, [3, 4]}
      assert right.length == 2
      assert right.id == ID.new(1, 2)
    end

    test "splits deleted content at offset" do
      item = Item.new(ID.new(1, 0), nil, nil, {:deleted, 5}, {:named, "text"}, nil)
      {left, right} = Item.split(item, 3)

      assert left.content == {:deleted, 3}
      assert left.length == 3
      assert right.content == {:deleted, 2}
      assert right.length == 2
    end

    test "preserves parent through split" do
      item = Item.new(ID.new(1, 0), nil, nil, {:string, "abc"}, {:named, "text"}, nil)
      {left, right} = Item.split(item, 1)

      assert left.parent == {:named, "text"}
      assert right.parent == {:named, "text"}
    end
  end
end
