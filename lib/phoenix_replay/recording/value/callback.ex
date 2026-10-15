defmodule PhoenixReplay.Recording.Value.Callback do
  @moduledoc "A non-executable function identity, without its captured environment."

  @enforce_keys [:arity, :origin]
  defstruct [:arity, :origin]

  def from_function(function) when is_function(function) do
    info = Function.info(function)

    origin =
      info
      |> Keyword.take([:module, :name, :arity, :type, :index, :new_uniq])
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    %__MODULE__{arity: info[:arity], origin: origin}
  end
end
