defmodule Explorer.Chain.Address.Token do
  @moduledoc """
  A projection that represents the relation between a Token and a specific Address.

  This representation is expressed by the following attributes:

  - contract_address_hash - Address of a Token's contract.
  - name - Token's name.
  - symbol - Token's symbol.
  - type - Token's type.
  - decimals - Token's decimals.
  - balance - how much tokens (TokenBalance) the Address has from the Token.
  - transfer_count - a count of how many TokenTransfers of the Token the Address was involved.
  """

  import Ecto.Query

  alias Explorer.{Chain, PagingOptions}
  alias Explorer.Chain.{Address, Hash}
  alias Explorer.Chain.Address.CurrentTokenBalance

  @enforce_keys [:contract_address_hash, :inserted_at, :name, :symbol, :balance, :decimals, :type]
  defstruct @enforce_keys

  @default_paging_options %PagingOptions{page_size: 50}
  @typep paging_options :: {:paging_options, PagingOptions.t()}

  @doc """
  It builds a paginated query of Address.Tokens that have a balance higher than zero ordered by type and name.
  """
  @spec list_address_tokens_with_balance(Hash.t(), [paging_options()]) :: Ecto.Query.t()
  def list_address_tokens_with_balance(address_hash, options \\ []) do
    paging_options = Keyword.get(options, :paging_options, @default_paging_options)

    address_hash
    |> join_with_last_balance()
    |> filter_and_group()
    |> order()
    |> page_tokens(paging_options)
    |> limit(^paging_options.page_size)
  end

  defp filter_and_group(query) do
    from(
      [token, balance] in query,
      where: balance.value > 0,
      select: %Address.Token{
        contract_address_hash: token.contract_address_hash,
        inserted_at: max(token.inserted_at),
        name: token.name,
        symbol: token.symbol,
        balance: balance.value,
        decimals: max(token.decimals),
        type: token.type
      },
      group_by: [token.name, token.symbol, balance.value, token.type, token.contract_address_hash, balance.block_number]
    )
  end

  defp order(query) do
    from(
      token in subquery(query),
      order_by: fragment("? DESC, ? ASC NULLS LAST", token.type, token.name)
    )
  end

  defp join_with_last_balance(address_hash) do
    last_balance_query =
      from(
        ctb in CurrentTokenBalance,
        where: ctb.address_hash == ^address_hash,
        select: %{
          value: ctb.value,
          token_contract_address_hash: ctb.token_contract_address_hash,
          block_number: ctb.block_number,
          max_block_number: over(max(ctb.block_number), :w)
        },
        windows: [
          w: [partition_by: [ctb.token_contract_address_hash, ctb.address_hash]]
        ]
      )

    from(
      t in Chain.Token,
      join: tb in subquery(last_balance_query),
      on: tb.token_contract_address_hash == t.contract_address_hash,
      where: tb.block_number == tb.max_block_number,
      distinct: t.contract_address_hash
    )
  end

  @doc """
  Builds the pagination according to the given key within `PagingOptions`.

  * it just returns the given query when the key is nil.
  * it composes another where clause considering the `type`, `name` and `inserted_at`.

  """
  def page_tokens(query, %PagingOptions{key: nil}), do: query

  def page_tokens(query, %PagingOptions{key: {nil, type, inserted_at}}) do
    where(
      query,
      [token],
      token.type < ^type or (token.type == ^type and is_nil(token.name) and token.inserted_at < ^inserted_at)
    )
  end

  def page_tokens(query, %PagingOptions{key: {name, type, inserted_at}}) do
    upper_name = String.downcase(name)

    where(
      query,
      [token],
      token.type < ^type or
        (token.type == ^type and (fragment("LOWER(?)", token.name) > ^upper_name or is_nil(token.name))) or
        (token.type == ^type and fragment("LOWER(?)", token.name) == ^upper_name and token.inserted_at < ^inserted_at)
    )
  end

  def page_tokens(query, %PagingOptions{key: {circulating_market_cap, holder_count, name, contract_address_hash}}) do
    from(token in query,
      where: ^page_tokens_circulating_market_cap(circulating_market_cap, holder_count, name, contract_address_hash)
    )
  end

  defp page_tokens_circulating_market_cap(nil, holder_count, name, contract_address_hash) do
    dynamic(
      [t],
      is_nil(t.circulating_market_cap) and ^page_tokens_holder_count(holder_count, name, contract_address_hash)
    )
  end

  defp page_tokens_circulating_market_cap(circulating_market_cap, holder_count, name, contract_address_hash) do
    dynamic(
      [t],
      is_nil(t.circulating_market_cap) or t.circulating_market_cap < ^circulating_market_cap or
        (t.circulating_market_cap == ^circulating_market_cap and
           ^page_tokens_holder_count(holder_count, name, contract_address_hash))
    )
  end

  defp page_tokens_holder_count(nil, name, contract_address_hash) do
    dynamic(
      [t],
      is_nil(t.holder_count) and ^page_tokens_name(name, contract_address_hash)
    )
  end

  defp page_tokens_holder_count(holder_count, name, contract_address_hash) do
    dynamic(
      [t],
      is_nil(t.holder_count) or t.holder_count < ^holder_count or
        (t.holder_count == ^holder_count and ^page_tokens_name(name, contract_address_hash))
    )
  end

  defp page_tokens_name(nil, contract_address_hash) do
    dynamic([t], is_nil(t.name) and ^page_tokens_contract_address_hash(contract_address_hash))
  end

  defp page_tokens_name(name, contract_address_hash) do
    dynamic(
      [t],
      is_nil(t.name) or
        (t.name > ^name or (t.name == ^name and ^page_tokens_contract_address_hash(contract_address_hash)))
    )
  end

  defp page_tokens_contract_address_hash(contract_address_hash) do
    dynamic([t], t.contract_address_hash > ^contract_address_hash)
  end
end
