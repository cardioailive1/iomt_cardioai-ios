// PrivacyPolicyView.swift
// In-app Privacy Policy. Loads the hosted privacy page.
// Also defines LegalWebView, shared with TermsAndConditionsView.

import SwiftUI
import WebKit

struct PrivacyPolicyView: View {
    private let url = URL(string: "https://cardioailiverpm.com/privacy")!
    @State private var isLoading = true

    var body: some View {
        ZStack {
            LegalWebView(url: url, isLoading: $isLoading)
            if isLoading {
                ProgressView()
            }
        }
        .background(ColorPalette.screenBackground.ignoresSafeArea())
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Minimal WKWebView wrapper for showing hosted legal pages in-app.
struct LegalWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LegalWebView
        init(_ parent: LegalWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
