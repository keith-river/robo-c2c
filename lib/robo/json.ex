defmodule Robo.JSON do
  @moduledoc "依存ライブラリなしの最小JSONエンコーダ（サーバ→ブラウザ方向のみ使用）"

  def encode(term), do: term |> enc() |> IO.iodata_to_binary()

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(a) when is_atom(a), do: str(Atom.to_string(a))
  defp enc(n) when is_integer(n), do: Integer.to_string(n)
  defp enc(f) when is_float(f), do: Float.to_string(f)
  defp enc(s) when is_binary(s), do: str(s)
  defp enc(l) when is_list(l), do: ["[", l |> Enum.map(&enc/1) |> Enum.intersperse(","), "]"]

  defp enc(m) when is_map(m) do
    pairs = for {k, v} <- m, do: [str(to_string(k)), ":", enc(v)]
    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp str(s), do: [?", for(<<c::utf8 <- s>>, do: esc(c)), ?"]

  defp esc(?"), do: "\\\""
  defp esc(?\\), do: "\\\\"
  defp esc(?\n), do: "\\n"
  defp esc(?\r), do: "\\r"
  defp esc(?\t), do: "\\t"
  defp esc(c) when c < 0x20, do: "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
  defp esc(c), do: <<c::utf8>>
end
