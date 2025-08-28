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
