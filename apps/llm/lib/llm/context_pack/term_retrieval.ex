defmodule Llm.ContextPack.TermRetrieval do
  @moduledoc """
  Pure lexical retrieval: ranks project-memory chunks by how many distinct
  terms from the question they contain.

  This catches questions that name no module or file ("where are the 500
  credits paid?") by matching identifiers and words such as `credits`,
  `first_pay` or `500` against function-sized chunks.
  """

  alias Llm.ProjectMemory.FileChunk

  @default_limit 4
  @default_per_file 2
  @min_word_length 4

  # Prose and tests mention many terms in long, loosely related chunks, so
  # they crowd out the code that actually answers the question. They are only
  # searched when the question asks for them.
  @code_extensions ~w(.ex .exs .heex .js .ts .tsx)
  @doc_words ~w(doc docs documentation readme changelog roadmap notes markdown)
  @test_words ~w(test tests spec specs)

  # Question words and generic code words that match almost every chunk.
  @stop_words ~w(
    about above actually after again also because been before being does doing
    done each else even every from have here into just like make many more most
    much must need only other over same should some such than that their them
    then there these they thing this those through under until very want were
    what when where which while will with would your
    code file files function functions module modules line lines project app
    happen happens happening work works working stop stops stopped paid paying
    twice called calls call return returns value values
  )

  @type opts :: [limit: pos_integer(), per_file: pos_integer(), exclude_paths: [String.t()]]

  @doc "Terms used for matching, lowercased, in first-seen order."
  @spec terms(String.t()) :: [String.t()]
  def terms(question) when is_binary(question) do
    ~r/[A-Za-z_][A-Za-z0-9_?!]*|\d{2,}/
    |> Regex.scan(question)
    |> List.flatten()
    # Trailing ?/! is sentence punctuation far more often than an Elixir
    # predicate name, and "valid" still matches `valid?` in code.
    |> Enum.map(
      &(&1
        |> String.downcase()
        |> String.trim_trailing("?")
        |> String.trim_trailing("!"))
    )
    |> Enum.flat_map(&expand_term/1)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.filter(&useful_term?/1)
    |> Enum.map(&stem/1)
    |> Enum.uniq()
  end

  @doc """
  Best-matching chunks for `question`. A chunk needs at least two distinct
  matching terms (or the only term, when the question has one), and at most
  `:per_file` chunks are taken from any single file.
  """
  @spec top_chunks(map(), String.t(), opts()) :: [FileChunk.t()]
  def top_chunks(project_memory, question, opts \\ []) when is_binary(question) do
    terms = terms(question)
    limit = Keyword.get(opts, :limit, @default_limit)
    per_file = Keyword.get(opts, :per_file, @default_per_file)
    excluded = opts |> Keyword.get(:exclude_paths, []) |> MapSet.new()
    min_score = if length(terms) <= 1, do: 1, else: 2
    search_docs? = Enum.any?(@doc_words, &(&1 in terms))
    search_tests? = Enum.any?(@test_words, &(&1 in terms))

    if terms == [] do
      []
    else
      project_memory
      |> Map.get(:files, %{})
      |> Enum.reject(fn {path, _memory} -> MapSet.member?(excluded, path) end)
      |> Enum.filter(fn {path, _memory} -> searchable?(path, search_docs?, search_tests?) end)
      |> Enum.flat_map(fn {_path, memory} -> Map.get(memory, :chunks, []) end)
      |> Enum.map(&{score(&1, terms), &1})
      |> Enum.filter(fn {score, _chunk} -> score >= min_score end)
      |> Enum.sort_by(fn {score, chunk} ->
        {-score, chunk_lines(chunk), chunk.path, chunk.start_line}
      end)
      |> take_per_file(per_file)
      |> Enum.take(limit)
      |> Enum.map(fn {_score, chunk} -> chunk end)
    end
  end

  defp searchable?(path, search_docs?, search_tests?) do
    test? = String.ends_with?(path, "_test.exs") or String.contains?(path, "/test/")
    code? = Path.extname(path) in @code_extensions

    cond do
      test? -> search_tests?
      code? -> true
      true -> search_docs?
    end
  end

  # Among equal scores, the smaller chunk is the more specific match.
  defp chunk_lines(%FileChunk{start_line: first, end_line: last})
       when is_integer(first) and is_integer(last),
       do: last - first

  defp chunk_lines(_chunk), do: 0

  defp score(%FileChunk{content: content}, terms) when is_binary(content) do
    haystack = String.downcase(content)
    Enum.count(terms, &String.contains?(haystack, &1))
  end

  defp score(_chunk, _terms), do: 0

  defp take_per_file(scored, per_file) do
    {kept, _counts} =
      Enum.reduce(scored, {[], %{}}, fn {_score, chunk} = entry, {kept, counts} ->
        count = Map.get(counts, chunk.path, 0)

        if count < per_file,
          do: {[entry | kept], Map.put(counts, chunk.path, count + 1)},
          else: {kept, counts}
      end)

    Enum.reverse(kept)
  end

  # `first_pay` also matches code that only says `first` or `pay`-something;
  # keep the whole identifier and its parts.
  defp expand_term(term) do
    case String.split(term, "_", trim: true) do
      [_single] -> [term]
      parts -> [term | parts]
    end
  end

  defp useful_term?(term) do
    Regex.match?(~r/^\d+$/, term) or String.length(term) >= @min_word_length
  end

  # Crude plural stripping so "credits" matches "credit" and "crates" "crate".
  defp stem(term) do
    if String.length(term) > @min_word_length and String.ends_with?(term, "s") and
         not String.ends_with?(term, "ss"),
       do: String.trim_trailing(term, "s"),
       else: term
  end
end
