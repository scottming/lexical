defmodule Lexical.RemoteControl.CodeMod.Rename.Entry do
  @moduledoc """
  """
  alias Lexical.RemoteControl.Search.Indexer

  # When renaming, we rely on the `Indexer.Entry`,
  # and we also need some other fields used exclusively for renaming, such as `edit_range`.
  defstruct [
    :id,
    :path,
    :subject,
    :block_range,
    :range,
    :edit_range
  ]

  def new(%Indexer.Entry{} = indexer_entry) do
    %__MODULE__{
      id: indexer_entry.id,
      path: indexer_entry.path,
      subject: indexer_entry.subject,
      block_range: indexer_entry.block_range,
      range: indexer_entry.range,
      edit_range: indexer_entry.range
    }
  end
end
