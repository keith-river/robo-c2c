defmodule Robo.WS do
  @moduledoc "WebSocket(RFC 6455)のハンドシェイク計算とフレームの符号化・復号（テキスト／制御フレームのみ）"

  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @max_payload 65_536

  def accept_key(key), do: :crypto.hash(:sha, key <> @guid) |> Base.encode64()

  @doc "サーバ→クライアントのフレーム（マスクなし）"
  def encode(op, payload) when is_binary(payload) do
    len = byte_size(payload)

    hdr =
      cond do
        len < 126 -> <<1::1, 0::3, op::4, len::8>>
        len < 65_536 -> <<1::1, 0::3, op::4, 126::8, len::16>>
        true -> <<1::1, 0::3, op::4, 127::8, len::64>>
      end

    [hdr, payload]
  end

  @doc """
  バッファから完結しているフレームを全て取り出す。
  戻り値: {[{opcode, payload}], 残りバッファ} か {:error, reason}
  """
  def decode(buf, acc \\ [])

  def decode(<<_fin::1, _rsv::3, op::4, mask::1, len::7, rest::binary>> = buf, acc) do
    case payload_len(len, rest) do
      {:ok, plen, rest2} when plen <= @max_payload ->
        mlen = if mask == 1, do: 4, else: 0

        if byte_size(rest2) >= mlen + plen do
          <<key::binary-size(mlen), payload::binary-size(plen), rest3::binary>> = rest2
          payload = if mask == 1, do: unmask(payload, key), else: payload
          decode(rest3, [{op, payload} | acc])
        else
          {Enum.reverse(acc), buf}
        end

      {:ok, _too_big, _} ->
        {:error, :too_big}

      :more ->
        {Enum.reverse(acc), buf}
    end
  end

  def decode(buf, acc), do: {Enum.reverse(acc), buf}

  defp payload_len(126, <<l::16, r::binary>>), do: {:ok, l, r}
  defp payload_len(127, <<l::64, r::binary>>), do: {:ok, l, r}
  defp payload_len(n, r) when n < 126, do: {:ok, n, r}
  defp payload_len(_, _), do: :more

  defp unmask(payload, key) do
    size = byte_size(payload)
    full = :binary.copy(key, div(size, 4) + 1)
    :crypto.exor(payload, binary_part(full, 0, size))
  end
end
