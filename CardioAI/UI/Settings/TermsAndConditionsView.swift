// TermsAndConditionsView.swift
// In-app Terms & Conditions. Loads the hosted terms page.

import SwiftUI

struct TermsAndConditionsView: View {
    private let url = URL(string: "https://cardioailiverpm.com/terms")!
    @State private var isLoading = true

    var body: some View {
        ZStack {
            LegalWebView(url: url, isLoading: $isLoading)
            if isLoading {
                ProgressView()
            }
        }
        .background(ColorPalette.screenBackground.ignoresSafeArea())
        .navigationTitle("Terms & Conditions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
