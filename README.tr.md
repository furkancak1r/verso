# Verso

[English](README.md) · **Türkçe**

Verso, uygulama pencerelerinin arkasına notlar yerleştiren yerel bir macOS menü çubuğu uygulamasıdır. Not açmak için **desteklenen bir pencerenin başlık çubuğundaki boş alana Option (⌥) tuşuyla sol tıklayın**. Uygulamaya dönmek için **Escape** veya **Geri** düğmesini kullanın.

**Güncel sürüm:** 1.2.3 (derleme 17) · **Hedef sistem:** macOS 14+ · **Universal paket:** Apple Silicon ve Intel

## Özellikler

- **Uygulamaya bağlı notlar:** aynı uygulamanın pencereleri ortak not sekmelerini kullanır. Farklı uygulamaların notları ayrıdır.
- **Yerel metin editörü:** metin seçimi, pano, Unicode, arama ve not penceresi açık kaldığı sürece her sekmeye ait ayrı Geri Al/Yinele geçmişi.
- **Not kütüphanesi:** arama, son notlar, sabitlenen notlar ve arşiv. Kaydedilen notlara ilgili uygulama kapandıktan sonra da erişilebilir.
- **Yerel depolama:** otomatik kayıt, kayıt hatasında taslağı koruma ve boş ya da yalnız boşluk içeren notları kaydetmeme.
- **Kişiselleştirme:** Türkçe ve İngilizce, Sistem/Açık/Koyu görünüm ve Girişte Başlat ayarı.

1.2.3 sürümü, kapanış animasyonunu hazırlamadan önce notu mevcut boyutunda dondurur ve AppKit’in ek pencere animasyonlarını kapatır. Sekme kapatma düğmeleri sekmenin içinde yer alır; üzerlerine gelindiğinde ve basıldığında görsel geri bildirim verir. Kapanış değişikliğinin son görsel doğrulaması henüz tamamlanmadı; [Doğrulama ve bilinen sınırlar](#doğrulama-ve-bilinen-sınırlar) bölümüne bakın.

## Kurulum

Dağıtım paketleri yerel olarak üretilir ve Git’e eklenmez. `build/releases/1.2.3/Verso-1.2.3-universal.dmg` dosyasını oluşturmak için [Kaynaktan derleme](#kaynaktan-derleme) bölümünü izleyin.

1. DMG’yi açıp **Verso.app** dosyasını **Applications (Uygulamalar)** klasörüne sürükleyin.
2. Disk görüntüsünü çıkarın ve `/Applications/Verso.app` dosyasını açın. Verso, Dock simgesi olmadan menü çubuğunda çalışır.
3. macOS ilk açılışı engellerse **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç** yolunu kullanın.
4. Verso’nun İzinler penceresi açıldığında **Erişilebilirlik** iznini verin. **Ekran Kaydı** isteğe bağlıdır ve dönüş önizlemesini etkinleştirir.

Ücretsiz paket, kalıcı ve kendinden imzalı bir sertifika kullanır. **Apple noter onayı veya Developer ID imzası yoktur.** Uygulamayı kullanmak için sertifika içe aktarmanız gerekmez. Gatekeeper açık kalır. Eski bir ad-hoc derlemeden ilk geçişte yeniden izin gerekebilir; test edilen Mac’te aynı sertifikayla yapılan güncellemede iki izin de korundu. Bu sonuç, her sistem veya sonraki tüm güncellemeler için garanti değildir. [Uyumluluk kaydına](docs/COMPATIBILITY.md) ve [Apple’ın Developer ID açıklamasına](https://developer.apple.com/developer-id/) bakın.

İzinler bölümünde uygulamanın bulunması gerekiyorsa **Ayarları Aç** düğmesini, ardından izin listesindeki **+** düğmesini kullanıp kurulu `Verso.app` dosyasını seçin. **Verso’yu Finder’da Göster**, çalışan kopyanın konumunu açar; Finder’da seçmek tek başına izin vermez. Her iki izin de verildiğinde kurulum yardımı gizlenir. Erişilebilirlik eksikse başlangıçta veya uygulama açıkça yeniden açıldığında İzinler penceresi gösterilir; yalnız isteğe bağlı Ekran Kaydı izninin eksik olması bu pencereyi açmaz.

## Kullanım

| İşlem | Kontrol |
| --- | --- |
| Not aç | Desteklenen başlık çubuğunun boş alanına Option-tıkla |
| Uygulamaya dön | Escape, Geri, kırmızı pencere düğmesi veya not başlığına Option-tıklama |
| Not sekmesi ekle | **+** veya **⌘T** |
| Sekme değiştir | **Control+Tab** / **Control+Shift+Tab** |
| Sekmeyi kapat | **×** veya **⌘W** |
| Metinde ara / Ayarlar’ı aç | **⌘F** / **⌘,** |

İçi dolu bir sekmeyi kapatmak notu **Arşiv**’e taşır. Boş sekme kapatıldığında atılır; son sekme kapatılırsa yeni bir boş sekme bırakılır. Sekmeler oluşturulma sırasını izler. Sekmeleri yeniden sıralama ve not penceresi ya da uygulama yeniden açıldığında Geri Al/Yinele geçmişini koruma desteklenmez.

Notu **Sabitlenen Notlar**’a eklemek için sabitleme düğmesine, sabiti kaldırmak için tekrar aynı düğmeye tıklayın. Dolu simge kaydedilmiş durumu gösterir. Başarı mesajı iki saniye görünür; kayıt hatasında önceki durum korunur ve hata beş saniye gösterilir. Mesaj editörü kaydırmaz veya klavye odağını değiştirmez.

Menü çubuğundaki kütüphane; not açmayı, sabitlemeyi, arşivlemeyi/arşivden çıkarmayı ve onaylı silmeyi destekler. **Pencereyi Göster**, o anda doğrulanabilen açık bir hedef pencere gerektirir. Boş notlar sabitlenemez veya arşivlenemez. Kaydedilmiş bir notun içini tamamen silmek notu kütüphaneden kaldırır; açık editörde Geri Al/Yinele aynı notu geri getirir/kaldırır. Önceden kaydedilmiş notlara toplu temizlik uygulanmaz.

Ekran Kaydı izniyle dönüş animasyonu, hedef pencerenin ve kırpılmış arka planın geçici görüntülerini kullanır; dönüşte hedefin güncel görüntüsü alınır. Kullanılabilir görüntü yoksa veya Hareketi Azalt açıksa geçiş doğrudan yapılır. Kontrollerin, içeriğin, iletişim panellerinin veya belirsiz başlık alanlarının üzerindeki tıklamalar işleme alınmaz.

Notu sürükleme ve boyutlandırma, asıl pencereyi küçültme ve tam ekran/büyütme kontrolleri genel macOS API’leriyle uygulanmıştır. Desteklenmeyen kontroller pasiftir. **Bu kontrollerin masaüstü kabul testleri tamamlanmamıştır; not başlığından sürükleme hatası hâlâ açıktır.**

## Dil ve ayarlar

**Ayarlar → Dil** bölümünde **Sistem / Türkçe / English** seçilir. Varsayılan Sistem’dir: Verso, macOS tercihlerindeki ilk desteklenen dili kullanır; eşleşme yoksa İngilizceye döner. Elle yapılan seçim kaydedilir ve sonraki açılışta uygulanır. Dil değişikliği açık notları yeniden oluşturmaz; hazır olduğunuzda uygulamayı kapatıp yeniden açın. Not metni, uygulama penceresi başlıkları ve dosya yolları çevrilmez.

Görünüm seçenekleri **Sistem / Açık / Koyu**’dur. Yeni bir ayar profilinde Girişte Başlat, `SMAppService.mainApp` ile bir kez kayıt yapmayı dener. Mevcut profillerin servis durumu korunur. Sonradan kapatma tercihi ve sistem onayı gereksinimi dikkate alınır; ilk kayıt başarısızsa otomatik tekrar denenmez. Ayarlar gerçek servis durumunu gösterir. Derleme veya paketleme işlemi giriş kaydı oluşturmaz.

## Depolama ve gizlilik

Notlar yaklaşık **400 ms** sonra otomatik kaydedilir; açıkça kapatma, sabitleme/arşivleme, hedef değişikliği veya uygulamadan çıkış öncesinde de kayıt yapılır. Kayıt hatasında taslak korunur; açıkça pencere değiştirme veya çıkış işlemi düzenlemeleri sessizce kaybettirmez.

Yerel SwiftData deposu `~/Library/Application Support/Verso/WindowNotes.store` yolundadır; standart veritabanı yardımcı dosyaları da bulunabilir. Depo, not metni ile asgari pencere/belge kimlik bilgilerini içerir. Tercihler uygulamaya ait UserDefaults alanında tutulur.

Uygulamada CloudKit entegrasyonu, ağ istemcisi, telemetri veya ekran görüntüsü geçmişi yoktur. Pencere, kırpılmış arka plan ve not önizleme görüntüleri yalnız dönüş sırasında bellekte tutulur; işlem tamamlandığında veya temizlendiğinde serbest bırakılır. Uygulama yakalanan görüntüleri veya küçük önizlemeleri diske yazmaz.

## Kaynaktan derleme

**Swift 6.3+ içeren tam Xcode** kullanın. Kayıtlı test ortamı macOS 26.6.2 üzerinde Xcode 26.6 / Swift 6.3.3’tür. Dağıtım hedefi macOS 14.0’dır; gerçek macOS 14 ve Intel donanımı üzerinde çalışma henüz doğrulanmamıştır. Uygulama için üçüncü taraf bağımlılık gerekmez. Xcode ile geliştirmek için `Verso.xcodeproj` dosyasını açın.

### İmzalama gereksinimi

Derleme betikleri ve Xcode, [`Resources/Signing.xcconfig`](Resources/Signing.xcconfig) içindeki açık sertifika parmak izini kullanır. Eşleşen kod imzalama sertifikası **ve özel anahtarı**, derlemeyi yapan kullanıcının Anahtarlık’ında bulunmalıdır. Kimlik eksik veya yanlışsa mevcut uygulama ya da paket değiştirilmeden işlem durur; ad-hoc imzaya geri dönülmez.

Bağımsız bir fork için Anahtar Zinciri Erişimi’nin Sertifika Yardımcısı ile bir kez kendi Kod İmzalama kimliğinizi oluşturun ve açık parmak izini bilinçli olarak değiştirin. Sonraki sürümlerde aynı kimliği kullanın. Özel anahtarlar pakete veya Git’e eklenmez ve otomatik dışa aktarılmaz; mevcut kimliği başka bir derleme bilgisayarına taşımak, sahibinin kontrolünde bir Anahtarlık yedeği gerektirir. Kimlik kaybolursa yeniden izin gerekebilir. Derleme komutları sertifika oluşturmaz, güven ayarını değiştirmez veya giriş kaydı yapmaz.

### Komutlar

```bash
./scripts/build.sh
./scripts/test.sh
./scripts/test-signing.sh
./scripts/check-resources.sh
./scripts/release.sh
```

`build.sh`, önceki uygulamayı koruyarak **çalışılan bilgisayarın mimarisi için `build/Verso.app`** paketini hazırlar, imzalar ve doğrular. `release.sh`, **arm64 + x86_64** mimarilerini, paketlenmiş İngilizce/Türkçe kaynakları, sürümü ve sabitlenmiş imzayı doğruladıktan sonra şu çıktıları yayımlar:

```text
build/releases/1.2.3/
├── Verso.app
├── Verso-1.2.3-universal.dmg
├── Verso-1.2.3-universal.zip
└── SHA256SUMS
```

DMG, Applications kısayolu ve iki dilde kurulum yönergesi içerir. Paketleme önceki paketleri korur; `/Applications`, çalışan uygulama, tercihler veya notları değiştirmez. Kaynak ölçüm aracı, sentetik 4K görüntülerle 60 temizleme döngüsü çalıştırır ve sayısal sonuçları `.build/resource-probe/result.json` dosyasına yazar.

Universal Xcode derlemesini doğrudan çalıştırmak için:

```bash
xcodebuild -project Verso.xcodeproj -scheme Verso \
  -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
  -derivedDataPath .build/UniversalRelease \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
```

Uygulama `.build/UniversalRelease/Build/Products/Release/Verso.app` yolundadır. Araç zinciri `DEVELOPER_DIR` ile seçilebilir. `VERSO_BUILD_IN_SANDBOX=1` seçeneği, mevcut bir otomasyon sandbox’ı içinde SwiftData makrolarını destekler; normal derlemelerde gerekmez.

## Doğrulama ve bilinen sınırlar

Son kayıtlı test paketi **16 grupta 322 testi** geçmiştir. 1.2.3 sürümünün universal/yerel derlemeleri, sabitlenmiş imzaları ve DMG/ZIP doğrulama toplamları geçmiştir. Kurulu uygulamadaki son masaüstü denemesi, girdi göndermeden kilit ekranında durdu; kapanış animasyonunun görsel kabulü bu nedenle bekliyor. Önceki başarılı sekme testleri, ayrı pencere kontrolü hatasını doğrulamaz. Gerçek oturum açma/yeniden başlatma, Intel/macOS 14 donanımı ve uygulama bazındaki tüm senaryolar henüz doğrulanmamıştır. Ayrıntılar [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md), kaynak ölçümleri ise [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) dosyasındadır.

İsteğe bağlı masaüstü test aracı, birim testlerinden ayrıdır:

```bash
./scripts/check-desktop.sh --self-check
./scripts/check-desktop.sh --run
./scripts/check-desktop.sh --run --app-path /Applications/Verso.app
```

Parametre verilmezse yalnız derlenir. `--run`, kilidi açık oturum ve Verso/test süreci için uygun izinler gerektirir; mevcut not editörü veya beklenmeyen hedef/odak varsa durur. Üretilmiş pencereler kullanır ve benzersiz adlara sahip `SmokeTarget-…` test notları bırakır. Panoyu okumaz, not silmez, izin/giriş ayarlarını değiştirmez ve görüntü dosyası yazmaz.

Pencere kontrolü aşamaları yerine sekme oluşturma, ayrı Geri Al/Yinele, aynı uygulamada paylaşım ve kapatma/boş sekmeyi atma kontrollerini çalıştırmak için `VERSO_SMOKE_TABS_ONLY=1` kullanın. Gerçek yakalamaya özgü genişletilmiş animasyon alanının gözlemlenmesini de zorunlu kılmak için `VERSO_SMOKE_REQUIRE_CAPTURE=1` ayarlayın. Bu gözlem piksel yerine pencere metaverisini okur. Bu kontroller, gerçek uygulama veya yeniden başlatma senaryolarının yerine geçmez.

## Kaynak yapısı

- `Sources/VersoCore`: kimlik, kalıcılık, otomatik kayıt, koordinatlar, girdi ve dönüş durumu/animasyonu.
- `Sources/Verso`: yerel arayüz, editör, kütüphane, ayarlar, Erişilebilirlik, yakalama ve pencere entegrasyonu.
- `Tests/VersoCoreTests`: üretim davranışı ve sentetik yerel kontroller.
- `scripts`: derleme, testler, dağıtım paketleme ve kaynak ölçümleri.
- `docs`: uyumluluk, performans kanıtları ve kalan test yönergeleri.

Uygulama simgesi `Resources/AppIcon.icns` olarak paketlenir; düzenlenebilir 1024 piksel kaynak görseli `Resources/AppIcon.png` dosyasıdır.
