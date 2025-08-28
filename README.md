# Bitnami → Bitnamilegacy Migration Script

Kubernetes cluster’ında kullanılan **Bitnami imajlarını** otomatik olarak **bitnamilegacy** yoluna çevirir.  
`Deployment`, `StatefulSet`, `DaemonSet` ve `CronJob` objelerini tarar; `containers` ve `initContainers` içindeki `bitnami/...` path’lerini **kalıcı** olarak `bitnamilegacy/...` yapar. İşlemden sonra rollout tamamlanana kadar bekler.

---

## ✨ Özellikler
- **Planlama:** Önceden nelerin değişeceğini gösterir (`plan`)
- **Etkileşimli mod:** Her kaynak için sorar → uygula/atla/patch göster (`interactive`)
- **Devam edebilme:** Yarıda kalırsa `continue` ile aynı yerden devam eder
- **Rollout takibi:** Deployment/StatefulSet/DaemonSet güncellenene dek bekler
- **Doğrulama:** Kalan `bitnami/` imajlarını tespit eder (`verify`)
- **Güvenli dönüşüm:** Sadece `bitnami/` → `bitnamilegacy/` (case-insensitive); tag/registry/CRD alanlarına dokunmaz

---

## 🚀 Kullanım
```bash
# 1) Plan
./bitnami_to_legacy.sh plan

# 2) Etkileşimli çalışma
./bitnami_to_legacy.sh interactive

# 3) Yarıda kaldıysan devam
./bitnami_to_legacy.sh continue

# 4) Doğrulama
./bitnami_to_legacy.sh verify
```

### Ortam Değişkenleri
- `STATE_FILE` → state/log dosyası (default: `bitnami-migration-state.jsonl`)
- `TIMEOUT` → rollout bekleme süresi (default: `180s`)
- `NAMESPACE_SELECTOR` → sadece belirtilen namespace’leri işler  
  - Örn: `NAMESPACE_SELECTOR="kube-system,redis-kuhub"`  
  - Verilmezse → **cluster’daki tüm namespace’ler** taranır
- `KINDS` → işlenecek workload türleri (default: `deploy,ds,sts,cronjob`)  
  - Örn: `KINDS="deploy,sts"` sadece Deployment ve StatefulSet’leri işler

---

## 🛠 Gereksinimler

Script’in çalışması için ortamda şu araçların kurulu olması gerekir:

- **`kubectl`** (cluster context’in doğru ayarlanmış olması gerekiyor)  
- **`jq`** (JSON parsing ve patch üretimi için)  
- **Linux/macOS shell** (Bash + coreutils)  

👉 RBAC tarafında kullanılan kimliğin şu izinlere sahip olması gerekir:
- `get`, `list`, `patch` yetkileri: `deployments`, `statefulsets`, `daemonsets`, `cronjobs`  
- `get`, `list` yetkileri: `pods` (rollout durumunu beklemek için)  

---

## ❓ Neden bu dönüşüm?

**28 Ağustos 2025** itibariyle Bitnami, Docker Hub’daki imaj dağıtım yapısını değiştirdi:

- `docker.io/bitnami/...` deposu artık **yalnızca “latest” tag’li** sınırlı imajları barındırıyor.  
- Sürüm numarasıyla kullanılan tüm eski imajlar **`docker.io/bitnamilegacy/...`** deposuna taşındı.  
- `bitnamilegacy` deposu **güncelleme almayacak**, sadece geçici/geçiş için saklanacak.  
- Bu geçişin nedeni: Bitnami, daha güvenli, kurumsal destekli ve SLSA-3 seviyesinde imajları barındıran **Bitnami Secure Images (BSI)** yapısına geçti.  

### 🎯 Etkisi
- Eğer manifest veya Helm chart’larınız hâlâ `bitnami/...` yolunu kullanıyorsa, yeni bir **node üzerinde** pod yeniden schedule edildiğinde (ör. autoscaling, node drain, node failure), image yeniden çekilecek ve artık bulunamadığı için **`ImagePullBackOff`** hatası yaşanacak.  
- Eğer pod aynı node üzerinde restart oluyorsa sorun çıkmaz, çünkü image local cache’de bulunur.  
- Bu script workload objelerindeki path’leri `bitnamilegacy/...` ile değiştirerek servislerin sorunsuz devam etmesini sağlar.  

---

## 📚 Referanslar
- Broadcom Tanzu Blog: **How to prepare for the Bitnami changes coming soon (18 Aug 2025)**  
  https://community.broadcom.com/tanzu/blogs/beltran-rueda-borrego/2025/08/18/how-to-prepare-for-the-bitnami-changes-coming-soon  
- GitHub: **bitnami/charts – Issue #35164**  
  https://github.com/bitnami/charts/issues/35164  

---

## 🧱 Güvenlik, Hata Senaryoları ve Davranış

### 1) Kalıcılık (Geçici değil)
- `kubectl patch --type=json` ile **üst nesnenin spec’i** güncellenir. Pod yeniden başlasa da, yeni pod’lar **güncellenmiş image** ile gelir.
- **Helm/ArgoCD/GitOps** kullanıyorsanız: Chart/values tarafında da `bitnamilegacy/` güncellemesi yapılmazsa sonraki “sync/upgrade” eski haline çevirebilir.

### 2) Rollout bekleme ve hata anında durma
- Deployment/DaemonSet/StatefulSet’te `kubectl rollout status` beklenir.  
- `TIMEOUT` aşılırsa ya da rollout başarısız olursa komut **non-zero** döner; script **durur**.

### 3) İdempotans & Yeniden Çalıştırma
- Daha önce güncellenmiş workload’lara tekrar çalıştırıldığında patch uygulanmaz.  
- `STATE_FILE` sayesinde **uygulanan** ve **başarıyla verify edilen** kaynaklar kayıtlıdır.  
- `continue` komutu yalnız eksik kalan kaynakları işler.

### 4) Loglama & State
- Her adım (applying, applied, verified) JSONL formatında `STATE_FILE` içine yazılır.  
- Örnek:
  ```json
  {"ts":"2025-08-28T09:21:43+03:00","phase":"applying","kind":"Deployment","namespace":"kube-system","name":"external-dns-uat-hub"}
  {"ts":"2025-08-28T09:21:58+03:00","phase":"verified","kind":"Deployment","namespace":"kube-system","name":"external-dns-uat-hub"}
  ```
- Böylece süreç kolayca audit edilebilir.

### 5) Verify
- `./bitnami_to_legacy.sh verify` → hâlâ `bitnami/` kullanan kaynakları listeler.  
- Çıktı örneği:
  ```
  UYARI: Deployment/foo (ns: bar) hâlâ bitnami içeriyor.
  OK: StatefulSet/redis (ns: redis-kuhub) legacy ile güncel.
  ```

### 6) Sık Karşılaşılan Hatalar
- **`ErrImagePull` / `ImagePullBackOff`:** Legacy imaj henüz taşınmamış olabilir → tekrar deneyin.  
- **Rollout timeout:** Yeni pod’lar readiness’te takılıyorsa `kubectl describe pod` ile analiz edin.  
- **RBAC forbidden:** ServiceAccount’a patch izni eklenmeli.  
- **Drift:** Helm/ArgoCD upstream güncellenmezse eskiye döner.  
- **CRD içi image alanları:** Script yalnızca workload’lara bakar.

### 7) Güvenli Deneme
- Patch uygulanmadan önce **server-side dry-run** yapılır; başarısızsa gerçek patch atılmaz.  
- Etkileşimli modda patch JSON gösterilip onay alınabilir.

---

## 🧪 Tipik Çalışma Akışı

1. **Planla**  
   ```bash
   ./bitnami_to_legacy.sh plan
   ```
2. **Etkileşimli uygula**  
   ```bash
   NAMESPACE_SELECTOR="kube-system,keycloak" ./bitnami_to_legacy.sh interactive
   ```
3. **Devam et**  
   ```bash
   ./bitnami_to_legacy.sh continue
   ```
4. **Doğrula**  
   ```bash
   ./bitnami_to_legacy.sh verify
   ```

---

## 🔒 Notlar
- Yalnızca `bitnami/` → `bitnamilegacy/` dönüşümü yapılır.  
- CRD içi özel alanlara dokunmaz.  
- Helm/ArgoCD kullanıyorsanız upstream değerlerinizi güncellemeyi unutmayın.
