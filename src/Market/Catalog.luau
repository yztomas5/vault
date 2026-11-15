--!strict
export type Kind = "Product" | "Pass" | "Subscription"

export type Item = {
	Kind: Kind,
	Id: number | string,
	Giftable: boolean?,
	GiftProduct: number?,
	DisplayName: string?,
}

export type Catalog = { [string]: Item }

local Catalog = {}

local KINDS = { Product = true, Pass = true, Subscription = true }

function Catalog.check(catalog: Catalog)
	assert(type(catalog) == "table", "[Market] the catalog must be a table")
	local products: { [number]: string } = {}
	local passes: { [number]: string } = {}
	for name, item in catalog do
		assert(type(name) == "string" and string.match(name, "^[%a_][%w_]*$"), `[Market] {tostring(name)} is not a valid item name`)
		assert(type(item) == "table" and KINDS[item.Kind], `[Market] {name} needs a Kind of Product, Pass or Subscription`)
		if item.Kind == "Subscription" then
			assert(type(item.Id) == "string" and #item.Id > 0, `[Market] the subscription {name} needs its text id`)
		else
			assert(type(item.Id) == "number" and item.Id > 0 and item.Id % 1 == 0, `[Market] {name} needs a whole number id`)
		end
		if item.Kind == "Product" then
			assert(products[item.Id :: number] == nil, `[Market] {name} and {products[item.Id :: number]} share a product id`)
			products[item.Id :: number] = name
		elseif item.Kind == "Pass" then
			assert(passes[item.Id :: number] == nil, `[Market] {name} and {passes[item.Id :: number]} share a pass id`)
			passes[item.Id :: number] = name
			if item.GiftProduct ~= nil then
				local gift = item.GiftProduct
				assert(type(gift) == "number" and gift > 0 and gift % 1 == 0, `[Market] the gift product of {name} must be a whole number id`)
				assert(products[gift] == nil, `[Market] the gift product of {name} is already used by {products[gift]}`)
				products[gift] = name
			end
		else
			assert(item.Giftable ~= true and item.GiftProduct == nil, `[Market] the subscription {name} cannot be gifted`)
		end
	end
end

function Catalog.byProduct(catalog: Catalog, productId: number): (string?, Item?)
	for name, item in catalog do
		if (item.Kind == "Product" and item.Id == productId) or (item.Kind == "Pass" and item.GiftProduct == productId) then
			return name, item
		end
	end
	return nil, nil
end

function Catalog.byPass(catalog: Catalog, passId: number): (string?, Item?)
	for name, item in catalog do
		if item.Kind == "Pass" and item.Id == passId then
			return name, item
		end
	end
	return nil, nil
end

function Catalog.bySubscription(catalog: Catalog, subscriptionId: string): (string?, Item?)
	for name, item in catalog do
		if item.Kind == "Subscription" and item.Id == subscriptionId then
			return name, item
		end
	end
	return nil, nil
end

function Catalog.giftable(item: Item): boolean
	if item.Kind == "Product" then
		return item.Giftable == true
	end
	return item.Kind == "Pass" and item.GiftProduct ~= nil
end

function Catalog.productId(item: Item): number?
	if item.Kind == "Product" then
		return item.Id :: number
	end
	return if item.Kind == "Pass" then item.GiftProduct else nil
end

function Catalog.displayName(catalog: Catalog, name: string): string
	local item = catalog[name]
	return if item and item.DisplayName then item.DisplayName else name
end

return Catalog
