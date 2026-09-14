defmodule PtcManagerWeb.Auth do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller

  def require_authenticated(conn, _opts) do
    if get_session(conn, :authenticated) do
      conn
    else
      conn
      |> put_flash(:error, "Sign in to open the maintainer console.")
      |> redirect(to: "/login")
      |> halt()
    end
  end

  def authenticate(conn, password) when is_binary(password) do
    expected = Application.fetch_env!(:ptc_manager, :admin_password)

    if secure_match?(password, expected) do
      conn
      |> configure_session(renew: true)
      |> put_session(:authenticated, true)
      |> put_session(:actor, "maintainer")
    else
      conn
    end
  end

  def authenticated?(conn), do: get_session(conn, :authenticated) == true

  @doc "Constant-time equality for a presented credential against the configured one."
  def secure_match?(left, right)
      when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
      do: Plug.Crypto.secure_compare(left, right)

  def secure_match?(_left, _right), do: false
end
