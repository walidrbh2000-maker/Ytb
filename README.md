# Creating the Markdown file for the step-by-step guide

guide_content = """# دليل النشر المعماري لنظام Xray على Google Cloud Run
## المستوى: Master Engineer
### المشروع: تجاوز المحدودية عبر بنية Google السحابية

هذا الدليل مخصص للتنفيذ المباشر عبر بيئة **Termux**. سننتقل من الصفر إلى امتلاك نفق بيانات خاص ومستقر تماماً.

---

## المرحلة الأولى: تهيئة البيئة (Bootstrap)
ابدأ بلصق أمر الأتمتة في واجهة Termux الأساسية. هذا الأمر سيقوم ببناء نظام **Debian** كامل داخل هاتفك وتثبيت أدوات جوجل.

```bash
# استبدل الروابط بمعلومات مستودعك الفعلي على GitHub
curl -sL [https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO_NAME/main/setup.sh](https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO_NAME/main/setup.sh) | bash
