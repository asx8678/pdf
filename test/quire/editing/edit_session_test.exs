defmodule Quire.Editing.EditSessionTest do
  use ExUnit.Case, async: true

  setup do
    # The application starts the production-named Registry in its supervision
    # tree, so it is already available.  We start a test-named supervisor to
    # avoid colliding with the production DynamicSupervisor.
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: Quire.Editing.TestSupervisor})

    %{doc_id: Ecto.UUID.autogenerate(), user_id: Ecto.UUID.autogenerate()}
  end

  describe "start_link" do
    test "starts a session", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "registers in the global registry", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      assert [{^pid, _}] = Registry.lookup(Quire.Editing.EditSessionRegistry, {doc_id, user_id})
    end
  end

  describe "apply" do
    test "prepends to journal", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      op = %{kind: "annot.add", data: %{}}
      assert {:ok, ^op} = Quire.Editing.EditSession.apply(pid, op)

      state = :sys.get_state(pid)
      assert length(state.journal) == 1
      assert hd(state.journal) == op
    end

    test "clears redo_stack", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      Quire.Editing.EditSession.apply(pid, %{kind: "annot.add", data: %{}})
      Quire.Editing.EditSession.undo(pid)
      Quire.Editing.EditSession.apply(pid, %{kind: "annot.add", data: %{x: 2}})

      assert {:error, :empty} = Quire.Editing.EditSession.redo(pid)
    end

    test "rejects invalid ops", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      assert {:error, :invalid_op} = Quire.Editing.EditSession.apply(pid, "not a map")
    end
  end

  describe "undo" do
    test "restores previous state", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      {:ok, _op} = Quire.Editing.EditSession.apply(pid, %{kind: "annot.add", data: %{x: 1}})
      {:ok, undone} = Quire.Editing.EditSession.undo(pid)

      # undone is the inverse of op — for now it returns the same op
      assert is_map(undone)
      assert undone.kind == "annot.add"
    end

    test "returns :empty on empty journal", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      assert {:error, :empty} = Quire.Editing.EditSession.undo(pid)
    end
  end

  describe "redo" do
    test "restores op after undo", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      {:ok, _op} = Quire.Editing.EditSession.apply(pid, %{kind: "text.add", data: %{text: "hello"}})
      {:ok, _undone} = Quire.Editing.EditSession.undo(pid)
      {:ok, redone} = Quire.Editing.EditSession.redo(pid)

      assert redone.kind == "text.add"
    end

    test "returns :empty on empty redo_stack", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      assert {:error, :empty} = Quire.Editing.EditSession.redo(pid)
    end
  end

  describe "dirty?" do
    test "starts as false", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      state = :sys.get_state(pid)
      refute state.dirty?
    end

    test "is set to true after apply", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      Quire.Editing.EditSession.apply(pid, %{kind: "annot.add"})

      state = :sys.get_state(pid)
      assert state.dirty?
    end
  end

  describe "touch" do
    test "resets idle timer without raising", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      assert :ok = Quire.Editing.EditSession.touch(pid)
    end
  end

  describe "subscribe" do
    test "adds caller to subscribers", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      assert :ok = Quire.Editing.EditSession.subscribe(pid)

      state = :sys.get_state(pid)
      assert MapSet.member?(state.subscribers, self())
    end
  end

  describe "get_state" do
    test "returns full session state", %{doc_id: doc_id, user_id: user_id} do
      pid =
        start_supervised!({Quire.Editing.EditSession, document_id: doc_id, user_id: user_id})

      state = Quire.Editing.EditSession.get_state(pid)

      assert state.document_id == doc_id
      assert state.user_id == user_id
      assert state.journal == []
      assert state.redo_stack == []
      refute state.dirty?
      assert state.subscribers == MapSet.new()
    end
  end

  describe "Editing context" do
    test "open_session starts or looks up a session", %{doc_id: doc_id, user_id: user_id} do
      {:ok, pid} = Quire.Editing.open_session(doc_id, user_id)
      assert is_pid(pid)

      # Second call returns the same pid
      {:ok, same_pid} = Quire.Editing.open_session(doc_id, user_id)
      assert pid == same_pid
    end

    test "apply/undo/redo through context", %{doc_id: doc_id, user_id: user_id} do
      {:ok, pid} = Quire.Editing.open_session(doc_id, user_id)

      assert {:ok, _} = Quire.Editing.apply(pid, %{kind: "annot.add"})
      assert {:ok, _} = Quire.Editing.undo(pid)
      assert {:ok, _} = Quire.Editing.redo(pid)
    end

    test "close_session stops a session", %{doc_id: _doc_id, user_id: user_id} do
      # Use a unique doc_id so the open above doesn't interfere
      doc_id = Ecto.UUID.autogenerate()
      {:ok, pid} = Quire.Editing.open_session(doc_id, user_id)

      assert :ok = Quire.Editing.close_session(doc_id, user_id)
      refute Process.alive?(pid)
    end

    test "close_session returns error for missing session" do
      assert {:error, :not_found} =
               Quire.Editing.close_session(Ecto.UUID.autogenerate(), Ecto.UUID.autogenerate())
    end
  end
end
