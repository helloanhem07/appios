import SwiftUI
import Foundation
import Security

private let apiBaseURL = "http://222.255.184.131:20128/v1"

@main
struct AIChatApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String
    let content: String
    init(id: UUID = UUID(), role: String, content: String) {
        self.id = id; self.role = role; self.content = content
    }
}

struct ORRequest: Codable {
    let model: String
    let messages: [ORMessage]
    let temperature: Double
}
struct ORMessage: Codable { let role: String; let content: String }
struct ORResponse: Codable { let choices: [ORChoice] }
struct ORChoice: Codable { let message: ORMessage }

final class KeychainStore {
    static let shared = KeychainStore()
    private let service = "AIChatApp.OmniRouter"
    func save(_ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "apiKey", kSecValueData as String: data]
        SecItemDelete(query as CFDictionary); SecItemAdd(query as CFDictionary, nil)
    }
    func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "apiKey", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "apiKey"]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isSending = false
    @Published var apiKey: String? = KeychainStore.shared.load()
    @Published var errorMessage: String?

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainStore.shared.save(trimmed); apiKey = trimmed
    }
    func clearKey() { KeychainStore.shared.delete(); apiKey = nil }

    func send() async {
        guard let key = apiKey, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSending else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        messages.append(ChatMessage(role: "user", content: text))
        isSending = true; errorMessage = nil
        defer { isSending = false }
        do {
            let body = ORRequest(model: "openai/gpt-4o-mini", messages: messages.map { ORMessage(role: $0.role, content: $0.content) }, temperature: 0.7)
            guard let url = URL(string: "\(apiBaseURL)/chat/completions") else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("AIChatApp", forHTTPHeaderField: "X-Title")
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let serverText = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "OmniRouter", code: 1, userInfo: [NSLocalizedDescriptionKey: "API request failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)). \(serverText)"])
            }
            let decoded = try JSONDecoder().decode(ORResponse.self, from: data)
            if let answer = decoded.choices.first?.message.content { messages.append(ChatMessage(role: "assistant", content: answer)) }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    @State private var showKeySheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if vm.messages.isEmpty {
                    Spacer(); Image(systemName: "sparkles").font(.system(size: 46)).padding(.bottom, 8)
                    Text("AI Chat").font(.largeTitle.bold())
                    Text("Chat through Omni Router").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(vm.messages) { msg in
                                    HStack { if msg.role == "assistant" { bubble(msg.content, false); Spacer() } else { Spacer(); bubble(msg.content, true) } }.id(msg.id)
                                }
                            }.padding()
                        }.onChange(of: vm.messages.count) { _ in if let id = vm.messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message...", text: $vm.input, axis: .vertical).textFieldStyle(.roundedBorder)
                    Button { Task { await vm.send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)) }.disabled(vm.isSending || vm.input.isEmpty || vm.apiKey == nil)
                }.padding()
            }
            .navigationTitle("AI Chat")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showKeySheet = true } label: { Image(systemName: "key.fill") } } }
            .sheet(isPresented: $showKeySheet) { APIKeyView(vm: vm) }
            .alert("Error", isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) { Button("OK") {} } message: { Text(vm.errorMessage ?? "") }
            .onAppear { if vm.apiKey == nil { showKeySheet = true } }
        }
    }
    private func bubble(_ text: String, _ user: Bool) -> some View {
        Text(text).padding(12).background(user ? Color.accentColor : Color.secondary.opacity(0.15)).foregroundStyle(user ? .white : .primary).clipShape(RoundedRectangle(cornerRadius: 16)).frame(maxWidth: 300, alignment: user ? .trailing : .leading)
    }
}

struct APIKeyView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Omni Router API Key") {
                    SecureField("API key", text: $key)
                    Text("The key is stored locally in the iOS Keychain.").font(.footnote).foregroundStyle(.secondary)
                }
                Button("Save") { vm.saveKey(key); dismiss() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if vm.apiKey != nil { Button("Remove API Key", role: .destructive) { vm.clearKey(); dismiss() } }
            }.navigationTitle("API Key").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }
}
