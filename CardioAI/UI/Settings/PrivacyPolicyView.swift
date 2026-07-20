// PrivacyPolicyView.swift
// In-app Privacy Policy. Body copy is a placeholder until Legal supplies the
// real text.

import SwiftUI

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            Text("need to update")
                .font(.system(size: 14))
                .foregroundStyle(ColorPalette.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .designCard(cornerRadius: 20)
                .padding(16)
        }
        .background(ColorPalette.screenBackground.ignoresSafeArea())
        .navigationTitle("Privacy Policy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
