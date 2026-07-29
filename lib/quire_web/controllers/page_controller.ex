defmodule QuireWeb.PageController do
  use QuireWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
