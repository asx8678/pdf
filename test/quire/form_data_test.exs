defmodule Quire.FormDataTest do
  use ExUnit.Case, async: true

  alias Quire.FormData

  describe "FDF" do
    test "round-trips through FDF" do
      data = %{"name" => "Ada", "age" => "31"}
      assert {:ok, fdf} = FormData.export(data, :fdf)
      assert {:ok, decoded} = FormData.import(fdf, :fdf)
      assert decoded == data
    end

    test "handles escaped parentheses" do
      data = %{"note" => "it(s fine"}
      assert {:ok, fdf} = FormData.export(data, :fdf)
      assert {:ok, decoded} = FormData.import(fdf, :fdf)
      assert decoded == data
    end

    test "handles backslash-escaping round-trip" do
      data = %{"path" => "C:\\Users\\test"}
      assert {:ok, fdf} = FormData.export(data, :fdf)
      assert {:ok, decoded} = FormData.import(fdf, :fdf)
      assert decoded == data
    end

    test "import handles simple FDF text" do
      fdf = ~s'%FDF-1.2\n1 0 obj\n<< /FDF << /Fields [\n  /T (name) /V (Ada)\n] >> >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n'
      assert {:ok, data} = FormData.import(fdf, :fdf)
      assert data == %{"name" => "Ada"}
    end
  end

  describe "XFDF" do
    test "round-trips through XFDF" do
      data = %{"name" => "Ada", "age" => "31"}
      assert {:ok, xfdf} = FormData.export(data, :xfdf)
      assert {:ok, decoded} = FormData.import(xfdf, :xfdf)
      assert decoded == data
    end

    test "handles XML special chars round-trip" do
      data = %{"note" => "price < 10 & valid"}
      assert {:ok, xfdf} = FormData.export(data, :xfdf)
      assert {:ok, decoded} = FormData.import(xfdf, :xfdf)
      assert decoded == data
    end

    test "import handles sample XFDF" do
      xfdf = ~s{<?xml version="1.0"?>
<xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
<fields>
<field name="name"><value>Ada</value></field>
</fields>
</xfdf>}

      assert {:ok, data} = FormData.import(xfdf, :xfdf)
      assert data == %{"name" => "Ada"}
    end
  end

  describe "JSON" do
    test "round-trips through JSON" do
      data = %{"name" => "Ada", "age" => "31"}
      assert {:ok, json} = FormData.export(data, :json)
      assert {:ok, decoded} = FormData.import(json, :json)
      assert decoded == data
    end

    test "import handles simple JSON" do
      assert {:ok, data} = FormData.import(~s({"name":"Ada"}), :json)
      assert data == %{"name" => "Ada"}
    end

    test "import rejects non-object JSON" do
      assert {:error, _} = FormData.import(~s(["Ada"]), :json)
    end

    test "import rejects invalid JSON" do
      assert {:error, _} = FormData.import("not json", :json)
    end
  end

  describe "CSV" do
    test "round-trips through CSV" do
      data = %{"name" => "Ada", "age" => "31"}
      assert {:ok, csv} = FormData.export(data, :csv)
      assert {:ok, decoded} = FormData.import(csv, :csv)
      assert decoded == data
    end

    test "import handles simple CSV" do
      csv = "name, age\nAda, 31\n"
      assert {:ok, data} = FormData.import(csv, :csv)
      assert data == %{"name" => "Ada", "age" => "31"}
    end

    test "import handles single-field CSV" do
      csv = "name\nAda\n"
      assert {:ok, data} = FormData.import(csv, :csv)
      assert data == %{"name" => "Ada"}
    end
  end
end
