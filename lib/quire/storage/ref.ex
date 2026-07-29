defmodule Quire.Storage.Ref do
  @moduledoc """
  An opaque reference to a stored blob.

  `Ref` is the only handle the rest of the application has to data in the
  storage layer. Its fields are documented here for maintainers of adapter
  modules; **code outside an adapter must never inspect `key`** — that field
  is meaningless outside the adapter that created it.

  | Field         | Type                          | Description                                          |
  |---------------|-------------------------------|------------------------------------------------------|
  | `adapter`     | `module()`                    | The adapter module that owns this ref.               |
  | `key`         | `String.t()`                  | Adapter-internal identifier. Opaque to callers.      |
  | `name`        | `String.t()`                  | Human-facing filename for download headers.          |
  | `content_type`| `String.t()` or `nil`         | MIME type.                                           |
  | `byte_size`   | `non_neg_integer()` or `nil`  | Size in bytes, if known without fetching.            |
  | `meta`        | `map()` or `nil`              | Arbitrary metadata keyed on atom.                    |

  ## Rules (§7.1)

  - `Ref.key` is meaningless to callers. **Nothing outside the adapter may
    inspect it.** Specifically: do not derive a filename from it for a
    download header — that is what `Ref.name` is for.
  - `%Plug.Upload{}` never crosses a context boundary.
    `consume_uploaded_entry/3` immediately produces a `Ref`.
  """

  defstruct [:adapter, :key, :name, :content_type, :byte_size, :meta]

  @type t :: %__MODULE__{
          adapter: module(),
          key: String.t(),
          name: String.t(),
          content_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          meta: map() | nil
        }
end
