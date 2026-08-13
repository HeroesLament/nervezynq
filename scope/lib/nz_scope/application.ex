defmodule NzScope.Application do
  @moduledoc false
  # wx_mvu starts as a dependency application; by the time we run, the
  # renderer and canvas supervisors exist. We add the Link (board client)
  # and then bring up the scene.

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NzScope.Link
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: NzScope.Supervisor)

    case WxMVU.start_scene(NzScope.Scenes.Main) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    {:ok, sup}
  end

  @doc "Hot-reload helper: tear the scene down and rebuild it."
  def reload do
    WxMVU.stop_scene(NzScope.Scenes.Main)
    WxMVU.start_scene(NzScope.Scenes.Main)
  end
end
