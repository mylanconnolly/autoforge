defmodule AutoforgeWeb.ErrorJSONTest do
  use AutoforgeWeb.ConnCase, async: true

  test "renders 404" do
    assert AutoforgeWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert AutoforgeWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
