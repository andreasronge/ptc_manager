defmodule PtcManagerWeb.AuthController do
  use PtcManagerWeb, :controller

  alias PtcManagerWeb.Auth

  def new(conn, _params) do
    if Auth.authenticated?(conn) do
      redirect(conn, to: ~p"/")
    else
      render(conn, :new, page_title: "Sign in")
    end
  end

  def create(conn, %{"password" => password}) do
    conn = Auth.authenticate(conn, password)

    if Auth.authenticated?(conn) do
      conn
      |> put_flash(:info, "Welcome back.")
      |> redirect(to: ~p"/")
    else
      conn
      |> put_flash(:error, "That password did not match.")
      |> render(:new, page_title: "Sign in")
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end
end
