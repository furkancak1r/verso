# Verso — çalışma talimatları

Önce `README.md`, `SPECIFICATION.md` ve `IMPLEMENTATION_PLAN.md` dosyalarını oku. Swift Package ve `Verso.xcodeproj` birlikte kullanılır; tam Xcode gerekir.

- Testler: `./scripts/test.sh` (`swift test` çalıştırır). Kaynak kontrolleri: `./scripts/check-resources.sh` ve `./scripts/test-signing.sh`.
- `./scripts/build.sh` yalnız derlemez; `build/Verso.app` dosyasını yeniden imzalayıp değiştirir ve eski uygulamayı `.build/` altına taşır. İzin verilmiş çalışan uygulama bu kopya olabileceği için açık istek olmadan çalıştırma.
- `./scripts/release.sh` paket üretir. `./scripts/check-desktop.sh --run` ise gerçek masaüstünde girdi verir. Bu iki komutu yalnız açık istekle çalıştır.
- İmzalama kimliği `Resources/Signing.xcconfig` içindeki sabit parmak iziyle eşleşmelidir. Sertifikayı, Keychain kayıtlarını ve parmak izini değiştirme.
- Kullanıcı notlarına (`~/Library/Application Support/Verso/`), `/Applications/Verso.app` kopyasına ve macOS izinlerine (Erişilebilirlik, Ekran Kaydı) dokunma. TCC veritabanını düzenleme.
- Gerçek uygulama veya masaüstü görüntülerini diske kaydetme; görsel testlerde yalnız sentetik içerik kullan.
