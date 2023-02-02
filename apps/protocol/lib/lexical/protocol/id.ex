defmodule Lexical.Protocol.Id do
  def next do
    [:monotonic, :positive]
    |> System.unique_integer()
    |> to_string()
  end
end
