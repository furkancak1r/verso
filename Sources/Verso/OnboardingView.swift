import SwiftUI

#if SWIFT_PACKAGE
import VersoCore
#endif

/// Explains the supported workflow without promising restoration that Verso
/// cannot prove safely.
struct OnboardingView: View {
    private let onOpenPermissions: (() -> Void)?

    init(onOpenPermissions: (() -> Void)? = nil) {
        self.onOpenPermissions = onOpenPermissions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L("window.howto"))
                    .font(.title2)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 16) {
                    step(
                        icon: "option",
                        title: L("ob.step1title"),
                        description: L("ob.step1desc")
                    )

                    step(
                        icon: "square.and.pencil",
                        title: L("ob.step2title"),
                        description: L("ob.step2desc")
                    )

                    step(
                        icon: "escape",
                        title: L("ob.step3title"),
                        description: L("ob.step3desc")
                    )

                    step(
                        icon: "externaldrive.badge.checkmark",
                        title: L("ob.step4title"),
                        description: L("ob.step4desc")
                    )

                    step(
                        icon: "accessibility",
                        title: L("ob.step5title"),
                        description: L("ob.step5desc")
                    )

                    step(
                        icon: "camera",
                        title: L("ob.step6title"),
                        description: L("ob.step6desc")
                    )
                }

                if let onOpenPermissions {
                    Button(L("ob.review"), action: onOpenPermissions)
                        .buttonStyle(.borderedProminent)
                }

                Text(L("ob.footnote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520)
    }

    private func step(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
