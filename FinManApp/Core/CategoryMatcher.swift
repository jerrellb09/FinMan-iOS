import Foundation

/// Maps free-text names ("Trader Joe's run", "Car insurance", "Food & dining") to the app's default categories by keyword.
nonisolated enum CategoryMatcher {
    /// Checked in order, so specific phrases ("gas bill", "car insurance") win over general ones ("gas", "insurance").
    private static let rules: [(category: String, phrases: [String], words: [String])] = [
        ("Income", ["paycheck", "pay check", "salary", "wages", "side hustle", "side gig", "freelance", "dividend", "interest income", "child support received", "income"],
         ["bonus", "commission", "stipend"]),
        ("Utilities", ["gas bill", "gas & electric", "gas and electric", "electric", "water", "sewer", "trash", "garbage", "utilit", "internet", "wifi", "wi-fi", "broadband",
                       "cable", "phone", "cell phone", "power bill", "energy", "verizon", "at&t", "t-mobile", "comcast", "xfinity", "spectrum"],
         ["power", "pg&e", "cell", "mobile"]),
        ("Subscriptions", ["subscription", "netflix", "spotify", "hulu", "disney", "hbo", "max streaming", "prime video", "amazon prime", "apple music", "apple one",
                           "icloud", "youtube", "paramount", "peacock", "audible", "patreon", "streaming", "chatgpt", "adobe", "microsoft 365"],
         []),
        ("Transportation", ["car insurance", "auto insurance", "car payment", "car note", "auto loan", "car loan", "gas station", "fuel", "gasoline", "parking",
                            "uber", "lyft", "transit", "metro", "subway", "bus pass", "car wash", "car maintenance", "oil change", "car registration", "dmv",
                            "vehicle", "shell", "chevron", "exxon"],
         ["car", "gas", "bus", "tires", "commute", "auto", "train", "toll", "tolls"]),
        ("Housing", ["mortgage", "property tax", "home insurance", "homeowner", "renters insurance", "renter's insurance", "housing", "home repair",
                     "home maintenance", "furniture", "lawn", "landlord", "apartment"],
         ["home", "house", "rent", "hoa"]),
        ("Healthcare", ["health", "medical", "doctor", "dentist", "dental", "vision insurance", "pharmacy", "prescription", "copay", "co-pay", "therapy", "therapist", "hospital",
                        "gym", "fitness", "cvs", "walgreens", "clinic"],
         ["meds", "medicine", "rx", "vision"]),
        ("Debt", ["credit card", "student loan", "personal loan", "debt", "loan payment", "minimum payment", "payoff", "sallie mae", "navient"],
         ["loan", "loans"]),
        ("Savings", ["saving", "emergency fund", "sinking fund", "invest", "retirement", "401(k)", "401k", "roth", "brokerage", "vanguard", "fidelity", "robinhood", "ira "],
         ["ira", "hsa", "stocks"]),
        ("Personal", ["dog food", "cat food", "pet food", "pet supplies", "vet bill"], ["vet", "pet", "pets"]),
        ("Food", ["grocer", "food", "dining", "restaurant", "takeout", "take-out", "take out", "coffee", "lunch", "dinner", "breakfast", "meal", "doordash", "uber eats",
                  "ubereats", "grubhub", "instacart", "trader joe", "whole foods", "safeway", "kroger", "costco", "aldi", "publix", "starbucks", "chipotle", "snack",
                  "eating out", "fast food", "bar tab", "drinks", "alcohol"],
         ["eats", "cafe", "pizza", "bakery"]),
        ("Travel", ["travel", "vacation", "flight", "airfare", "airline", "hotel", "airbnb", "trip", "holiday travel", "cruise", "luggage"],
         []),
        ("Education", ["tuition", "school", "college", "course", "textbook", "student", "education", "tutoring", "udemy", "coursera"],
         ["books", "book", "class", "classes"]),
        ("Entertainment", ["entertainment", "movie", "cinema", "concert", "games", "gaming", "steam", "playstation", "xbox", "nintendo", "hobby", "hobbies",
                           "fun money", "date night", "bowling", "sports", "tickets"],
         ["fun", "music", "party", "event", "events"]),
        ("Shopping", ["shopping", "clothes", "clothing", "apparel", "shoes", "amazon", "target", "walmart", "household", "home goods", "electronics", "ikea", "best buy"],
         []),
        ("Personal", ["personal", "haircut", "salon", "barber", "beauty", "cosmetic", "nails", "toiletries", "pet food", "pet insurance", "childcare",
                      "daycare", "babysit", "kids", "allowance", "gift", "donation", "charity", "church", "tithe", "laundry", "dry clean"],
         ["hair", "spa", "pet", "pets", "vet", "dog", "cat"]),
    ]

    /// The default category a name most likely belongs to, or nil when no keyword fits.
    static func match(_ name: String) -> String? {
        let l = " " + name.lowercased() + " "
        let words = Set(l.split { !$0.isLetter && !$0.isNumber && $0 != "&" }.map(String.init))
        for rule in rules where rule.phrases.contains(where: l.contains) || rule.words.contains(where: words.contains) {
            return rule.category
        }
        return nil
    }

    /// An existing category whose name matches (ignoring case, "&"/"and", and a trailing "s").
    static func existing(_ name: String, in names: [String]) -> String? {
        func key(_ s: String) -> String {
            var k = s.lowercased().replacingOccurrences(of: "&", with: "and").filter { $0.isLetter || $0.isNumber }
            if k.hasSuffix("s") { k.removeLast() }
            return k
        }
        let target = key(name)
        guard !target.isEmpty else { return nil }
        return names.first { key($0) == target }
    }
}
