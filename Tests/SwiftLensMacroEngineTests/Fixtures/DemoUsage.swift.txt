import Foundation

@MemberwiseInit
@AutoDescription
struct User {
    var name: String
    var age: Int = 0
    @UserDefault("theme") var theme: String = "light"
}

final class API {
    @AddAsync
    func fetchUser(id: Int, completion: @escaping (User) -> Void) {
        completion(User(name: "Taylor", age: 42))
    }
}

enum Keys {
    #constants("apiKey", "baseURL")
}

let (value, code) = #stringify(1 + 2 * 3)

@MemberwiseInit
enum NotAStruct {}
