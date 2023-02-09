defmodule Lexical.Server.Configuration do
  alias Lexical.Dialyzer
  alias Lexical.Project
  alias Lexical.Protocol.Id
  alias Lexical.Protocol.Notifications.DidChangeConfiguration
  alias Lexical.Protocol.Proto.LspTypes.Registration
  alias Lexical.Protocol.Requests
  alias Lexical.Protocol.Requests.RegisterCapability
  alias Lexical.Protocol.Types.ClientCapabilities
  alias Lexical.Server.Configuration.Support

  defstruct project: nil,
            support: nil,
            additional_watched_extensions: nil,
            dialyzer_enabled?: false

  @type t :: %__MODULE__{}

  @spec new(Lexical.uri(), map()) :: t
  def new(root_uri, %ClientCapabilities{} = client_capabilities) do
    support = Support.new(client_capabilities)
    project = Project.new(root_uri)
    %__MODULE__{support: support, project: project}
  end

  @spec default(t) ::
          {:ok, t}
          | {:ok, t, Requests.RegisterCapabilities.t()}
          | {:restart, Logger.level(), String.t()}
  def default(%__MODULE__{} = config) do
    apply_config_change(config, default_config())
  end

  @spec on_change(t, DidChangeConfiguration.t()) ::
          {:ok, t}
          | {:ok, t, Requests.RegisterCapability.t()}
          | {:restart, Logger.level(), String.t()}
  def on_change(%__MODULE__{} = old_config, :defaults) do
    apply_config_change(old_config, default_config())
  end

  def on_change(%__MODULE__{} = old_config, %DidChangeConfiguration{} = change) do
    apply_config_change(old_config, change.lsp.settings)
  end

  defp default_config do
    %{}
  end

  defp apply_config_change(%__MODULE__{} = old_config, %{} = settings) do
    with {:ok, new_config} <- maybe_set_env_vars(old_config, settings),
         {:ok, new_config} <- maybe_enable_dialyzer(new_config, settings) do
      maybe_add_watched_extensions(new_config, settings)
    end
  end

  defp maybe_set_env_vars(%__MODULE__{} = old_config, settings) do
    env_vars = Map.get(settings, "envVariables")

    with {:ok, new_project} <- Project.set_env_vars(old_config.project, env_vars) do
      {:ok, %__MODULE__{old_config | project: new_project}}
    end
  end

  defp maybe_enable_dialyzer(%__MODULE__{} = old_config, settings) do
    enabled? =
      case Dialyzer.check_support() do
        :ok ->
          Map.get(settings, "dialyzerEnabled", true)

        _ ->
          false
      end

    {:ok, %__MODULE__{old_config | dialyzer_enabled?: enabled?}}
  end

  defp maybe_add_watched_extensions(%__MODULE__{} = old_config, %{
         "additionalWatchedExtensions" => []
       }) do
    {:ok, old_config}
  end

  defp maybe_add_watched_extensions(%__MODULE__{} = old_config, %{
         "additionalWatchedExtensions" => extensions
       })
       when is_list(extensions) do
    register_id = Id.next()
    request_id = Id.next()

    watchers = Enum.map(extensions, fn ext -> %{"globPattern" => "**/*#{ext}"} end)

    registration =
      Registration.new(
        id: request_id,
        method: "workspace/didChangeWatchedFiles",
        register_options: %{"watchers" => watchers}
      )

    request = RegisterCapability.new(id: register_id, registrations: [registration])

    {:ok, old_config, request}
  end

  defp maybe_add_watched_extensions(%__MODULE__{} = old_config, _) do
    {:ok, old_config}
  end
end