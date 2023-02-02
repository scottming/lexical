defmodule Lexical.Provider.CodeAction.ReplaceWithUnderscore do
  @moduledoc """
  A code action that prefixes unused variables with an underscore
  """
  alias Lexical.CodeMod
  alias Lexical.CodeMod.Ast
  alias Lexical.Protocol.Requests.CodeAction
  alias Lexical.Protocol.Types.CodeAction, as: CodeActionResult
  alias Lexical.Protocol.Types.Diagnostic
  alias Lexical.Protocol.Types.Workspace
  alias Lexical.SourceFile

  @spec apply(CodeAction.t()) :: [CodeActionReply.t()]
  def apply(%CodeAction{} = code_action) do
    source_file = code_action.source_file
    diagnostics = get_in(code_action, [:context, :diagnostics]) || []

    Enum.flat_map(diagnostics, fn %Diagnostic{} = diagnostic ->
      with {:ok, variable_name, one_based_line} <- extract_variable_and_line(diagnostic),
           {:ok, reply} <- build_code_action(source_file, one_based_line, variable_name) do
        [reply]
      else
        _ ->
          []
      end
    end)
  end

  defp build_code_action(%SourceFile{} = source_file, one_based_line, variable_name) do
    with {:ok, line_text} <- SourceFile.fetch_text_at(source_file, one_based_line),
         {:ok, line_ast} <- Ast.from(line_text),
         {:ok, text_edits} <-
           CodeMod.ReplaceWithUnderscore.text_edits(line_text, line_ast, variable_name) do
      case text_edits do
        [] ->
          :error

        [_ | _] ->
          reply =
            CodeActionResult.new(
              title: "Rename to _#{variable_name}",
              kind: :quick_fix,
              edit: Workspace.Edit.new(changes: %{source_file.uri => text_edits})
            )

          {:ok, reply}
      end
    end
  end

  defp extract_variable_and_line(%Diagnostic{} = diagnostic) do
    with {:ok, variable_name} <- extract_variable_name(diagnostic.message),
         {:ok, line} <- extract_line(diagnostic) do
      {:ok, variable_name, line}
    end
  end

  @variable_re ~r/variable "([^"]+)" is unused/
  defp extract_variable_name(message) do
    case Regex.scan(@variable_re, message) do
      [[_, variable_name]] ->
        {:ok, String.to_atom(variable_name)}

      _ ->
        :error
    end
  end

  defp extract_line(%Diagnostic{} = diagnostic) do
    {:ok, diagnostic.range.start.line}
  end
end
