defmodule QuireWeb.PageController do
  use QuireWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/users/log-in")
  end
end
