defmodule PhoenixReplay.Sanitizer.SerializableTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.Sanitizer.Serializable
  alias PhoenixReplay.Recording.Value.Callback

  defmodule Account do
    defstruct [:name, :callback]
  end

  test "replaces runtime values in nested maps, structs, lists and tuples" do
    port = Port.open({:spawn, "cat"}, [])
    reference = make_ref()

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    values = %{
      function: &Enum.count/1,
      pid: self(),
      port: port,
      reference: reference,
      account: %Account{name: "n", callback: &String.upcase/1},
      nested: [%{runtime: self()}, {:ok, &Enum.count/1}]
    }

    assert %{function: %Callback{arity: 1}, pid: nil, port: nil, reference: nil} =
             Serializable.sanitize_assigns(values)

    assert %Account{name: "n", callback: %Callback{arity: 1}} =
             Serializable.sanitize_assigns(values).account

    assert [%{runtime: nil}, {:ok, %Callback{arity: 1}}] =
             Serializable.sanitize_assigns(values).nested
  end

  test "keeps forms as forms while removing runtime values from their fields" do
    form = Phoenix.Component.to_form(%{"name" => "n", "callback" => &Enum.count/1}, as: :user)
    %{form: sanitized} = Serializable.sanitize_assigns(%{form: form})

    assert %Phoenix.HTML.Form{} = sanitized
    assert sanitized.source["callback"] == Callback.from_function(&Enum.count/1)
    assert sanitized.options == []
  end

  test "keeps typed DateTime values and tuple shapes" do
    now = DateTime.utc_now()
    values = %{timestamp: now, result: {:ok, %{nested: {:timestamp, now}}}}
    sanitized = Serializable.sanitize_assigns(values)

    assert %DateTime{} = sanitized.timestamp
    assert sanitized.timestamp == now
    assert {:ok, %{nested: {:timestamp, %DateTime{} = nested}}} = sanitized.result
    assert nested == now
  end

  test "keeps replay metadata while filtering nested secrets" do
    values = %{
      password_field: :password,
      sign_in_token_params: %{token: "secret-token", remember_me: false},
      password: "secret-password",
      callback: &Enum.count/1
    }

    assert %{
             password_field: :password,
             sign_in_token_params: %{token: "[FILTERED]", remember_me: false},
             password: "[FILTERED]",
             callback: %Callback{arity: 1}
           } = Serializable.sanitize_assigns(values)
  end
end
