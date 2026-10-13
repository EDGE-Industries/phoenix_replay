defmodule PhoenixReplay.Storage.Writer do
  @moduledoc false

  def command(pid) do
    case :os.type() do
      {:win32, _name} -> {"tasklist", ["/FI", "PID eq #{pid}", "/NH"]}
      {:unix, _name} -> {"kill", ["-0", pid]}
    end
  end
end
