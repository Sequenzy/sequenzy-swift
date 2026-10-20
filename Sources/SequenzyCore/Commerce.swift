import Foundation

/// A product, with the same fields as the web SDK's `viewedProduct`.
public struct CommerceProduct: Equatable, Sendable {
    public var providerProductId: String
    public var providerVariantId: String?
    public var title: String?
    public var variantTitle: String?
    public var imageUrl: String?
    public var url: String?
    /// Major units, for example 19.99; or set `priceCents`.
    public var price: Double?
    public var priceCents: Int?
    public var currency: String?
    public var sku: String?

    public init(
        providerProductId: String, providerVariantId: String? = nil, title: String? = nil,
        variantTitle: String? = nil, imageUrl: String? = nil, url: String? = nil, price: Double? = nil,
        priceCents: Int? = nil, currency: String? = nil, sku: String? = nil
    ) {
        self.providerProductId = providerProductId
        self.providerVariantId = providerVariantId
        self.title = title
        self.variantTitle = variantTitle
        self.imageUrl = imageUrl
        self.url = url
        self.price = price
        self.priceCents = priceCents
        self.currency = currency
        self.sku = sku
    }

    var json: [String: JSONValue] {
        var object: [String: JSONValue] = ["providerProductId": .string(providerProductId)]
        if let providerVariantId { object["providerVariantId"] = .string(providerVariantId) }
        if let title { object["title"] = .string(title) }
        if let variantTitle { object["variantTitle"] = .string(variantTitle) }
        if let imageUrl { object["imageUrl"] = .string(imageUrl) }
        if let url { object["url"] = .string(url) }
        if let price { object["price"] = .number(price) }
        if let priceCents { object["priceCents"] = .number(Double(priceCents)) }
        if let currency { object["currency"] = .string(currency) }
        if let sku { object["sku"] = .string(sku) }
        return object
    }
}

public struct CommerceCartLine: Equatable, Sendable {
    public var product: CommerceProduct
    public var quantity: Int
    public var lineItemId: String?

    public init(product: CommerceProduct, quantity: Int, lineItemId: String? = nil) {
        self.product = product
        self.quantity = quantity
        self.lineItemId = lineItemId
    }

    var json: [String: JSONValue] {
        var object = product.json
        object["quantity"] = .number(Double(quantity))
        if let lineItemId { object["lineItemId"] = .string(lineItemId) }
        return object
    }
}

public struct CommerceCart: Equatable, Sendable {
    public var lineItems: [CommerceCartLine]
    public var cartId: String?
    public var totalQuantity: Int?
    public var totalPriceCents: Int?
    public var currency: String?

    public init(
        lineItems: [CommerceCartLine], cartId: String? = nil, totalQuantity: Int? = nil,
        totalPriceCents: Int? = nil, currency: String? = nil
    ) {
        self.lineItems = lineItems
        self.cartId = cartId
        self.totalQuantity = totalQuantity
        self.totalPriceCents = totalPriceCents
        self.currency = currency
    }

    var json: [String: JSONValue] {
        var object: [String: JSONValue] = [
            "itemCount": .number(Double(lineItems.count)),
            "lineItems": .array(lineItems.map { .object($0.json) }),
        ]
        if let cartId { object["cartId"] = .string(cartId) }
        if let totalQuantity { object["totalQuantity"] = .number(Double(totalQuantity)) }
        if let totalPriceCents { object["totalPriceCents"] = .number(Double(totalPriceCents)) }
        if let currency { object["currency"] = .string(currency) }
        return object
    }
}

public struct CommerceCollection: Equatable, Sendable {
    public var providerCollectionId: String
    public var title: String?
    public var handle: String?
    public var url: String?

    public init(providerCollectionId: String, title: String? = nil, handle: String? = nil, url: String? = nil) {
        self.providerCollectionId = providerCollectionId
        self.title = title
        self.handle = handle
        self.url = url
    }

    var json: [String: JSONValue] {
        var object: [String: JSONValue] = ["providerCollectionId": .string(providerCollectionId)]
        if let title { object["title"] = .string(title) }
        if let handle { object["handle"] = .string(handle) }
        if let url { object["url"] = .string(url) }
        return object
    }
}

/// A change to the signed-in contact's profile.
public struct ProfileUpdate: Equatable, Sendable {
    /// A name to set, or `.clear` to remove it. Nil leaves it as it is.
    public enum Name: Equatable, Sendable {
        case set(String)
        case clear
    }

    public var firstName: Name?
    public var lastName: Name?
    /// Custom attributes merged into the contact's; `.null` clears one.
    public var attributes: [String: JSONValue]?

    public init(firstName: Name? = nil, lastName: Name? = nil, attributes: [String: JSONValue]? = nil) {
        self.firstName = firstName
        self.lastName = lastName
        self.attributes = attributes
    }

    var json: [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        switch firstName {
        case .set(let value): object["firstName"] = .string(value)
        case .clear: object["firstName"] = .null
        case nil: break
        }
        switch lastName {
        case .set(let value): object["lastName"] = .string(value)
        case .clear: object["lastName"] = .null
        case nil: break
        }
        if let attributes { object["attributes"] = .object(attributes) }
        return object
    }
}

/// A newsletter or waitlist signup through a published Sequenzy form.
public struct SubscribeRequest: Equatable, Sendable {
    public var formId: String
    public var email: String
    public var firstName: String?
    public var lastName: String?
    /// For forms with a phone field; E.164 such as +14155550123.
    public var phone: String?
    /// Values for the form's custom fields.
    public var attributes: [String: JSONValue]?

    public init(
        formId: String, email: String, firstName: String? = nil, lastName: String? = nil,
        phone: String? = nil, attributes: [String: JSONValue]? = nil
    ) {
        self.formId = formId
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.phone = phone
        self.attributes = attributes
    }
}

public enum SubscribeResult: Equatable, Sendable {
    case success
    case failure(error: String, retryable: Bool)
}
