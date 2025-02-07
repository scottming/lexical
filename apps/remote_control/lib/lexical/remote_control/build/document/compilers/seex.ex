defmodule Lexical.RemoteControl.Build.Document.Compilers.Seex do
  @moduledoc """
  A compiler for .heex files
  """
  alias Lexical.Document
  alias Lexical.Plugin.V1.Diagnostic.Result
  alias Lexical.RemoteControl.Build.Document.Compiler
  alias Lexical.RemoteControl.Build.Document.Compilers
  require Logger

  @behaviour Compiler

  def recognizes?(%Document{language_id: "seex"}), do: true
  def recognizes?(_), do: false

  def enabled? do
    true
  end

  def compile(%Document{} = document) do
    with {:ok, heex} <- sendgrid_to_heex(document),
         {:ok, quoted} <- heex_to_quoted(document, heex) do
      Compilers.EEx.eval_quoted(document, quoted)
    end
  end

  defp sendgrid_to_heex(document) do
    source = Document.to_string(document)

    with {:ok, eex} <- Zappa.Sendgrid.compile(source) do
      {:ok, eex_href_to_heex_href(eex)}
    else
      {:error, error} ->
        Logger.error("Failed to convert Sendgrid EEx to HEEx: #{inspect(error)}")
        {:error, error}
    end
  end

  @eex_heex_href [
    {
      {~r/href="(.*?)<%= (.*?) %>"/, ~s|href="\\1{ \\2 }"|},
      {~r/href="(.*?){ (.*?) }"/, ~s|href="\\1<%= \\2 %>"|}
    },
    {~s|clicktracking=off|, ~s|clicktracking="off"|}
  ]

  defp eex_href_to_heex_href(content) do
    Enum.reduce(@eex_heex_href, content, fn
      {{eex, heex}, _heex}, acc ->
        # regex eex -> heex
        String.replace(acc, eex, heex)

      {eex, heex}, acc ->
        # eex -> heex
        String.replace(acc, eex, heex)
    end)
  end

  defp heex_to_quoted(%Document{} = document, heex_source) do
    try do
      opts =
        [
          source: heex_source,
          file: document.path,
          caller: __ENV__,
          engine: Phoenix.LiveView.TagEngine,
          subengine: Phoenix.LiveView.Engine,
          tag_handler: Phoenix.LiveView.HTMLEngine
        ]

      quoted = EEx.compile_string(heex_source, opts)

      {:ok, quoted}
    rescue
      error ->
        err = error_to_result(document, error)
        # Logger.info("Failed to compile HEEx to quoted: #{inspect(err)}")
        {:error, [err]}
    end
  end

  defp error_to_result(%Document{} = document, %EEx.SyntaxError{} = error) do
    position = {error.line, error.column}
    Result.new(document.uri, position, error.message, :error, "EEx")
  end

  defp error_to_result(document, %error_struct{} = error)
       when error_struct in [
              SyntaxError,
              TokenMissingError
            ] do
    position = {error.line, error.column}
    Result.new(document.uri, position, error.description, :error, "SEEx")
  end

  defp error_to_result(document, %Phoenix.LiveView.Tokenizer.ParseError{} = error) do
    position = {error.line - 1, 1}
    Result.new(document.uri, position, error.description, :error, "SEEx")
  end
end
