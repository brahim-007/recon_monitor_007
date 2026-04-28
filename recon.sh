#!/bin/bash

# --- إعدادات وتنسيق ---
print_status() { echo -e "\e[34m[*] $1...\e[0m"; }
JUNK_FILTER="(google-analytics|googletag|doubleclick|adsystem|facebook|fbcdn|gtag|tagmanager|hotjar|clarity|png|jpg|css|google|youtube|linkedin|svg|woff|woff2|ttf|otf|ico)"

DOMAIN="myprotein.com"

# --- 1. مراقبة النطاقات الفرعية ---
print_status "Subdomain Discovery"
subfinder -d $DOMAIN -silent | sort -u | httpx -fc 404 -silent | anew all-domains.txt > new_domains.txt
if [ -s new_domains.txt ]; then
    cat new_domains.txt | notify -id subdomains
fi

# --- 2. جمع الروابط مع الفلترة الفورية ---
print_status "URL Discovery & Filtering"
# الجمع السلبي (GAU) مع فلترة الروابط غير المهمة فوراً
cat all-domains.txt | gau --threads 10 | grep -viE "$JUNK_FILTER" | uro > wayback_raw.txt

# الجمع النشط (Katana) مع فلترة فورية
katana -list all-domains.txt -d 3 -jc -silent | grep -viE "$JUNK_FILTER" > katana_raw.txt

# دمج الروابط وفحص الحية منها
cat wayback_raw.txt katana_raw.txt | sort -u | httpx -mc 200,301,302,403,404 -silent | anew all_live_urls.txt > new_urls.txt
if [ -s new_urls.txt ]; then
    cat new_urls.txt | notify -id endpoint
fi

# --- 3. استخراج الـ JS وتحديد الجديد منه ---
print_status "Extracting JS Files"
grep -Ei "\.js(\?|$)" all_live_urls.txt | grep -viE "$JUNK_FILTER" > raw_js.txt

# استخدام getJS
cat all_live_urls.txt | getJS --complete --output getjs_results.txt

# التصفية النهائية والمقارنة (هنا يتم تحديث FINAL_JS_ENDPOINTS.txt تلقائياً)
cat raw_js.txt getjs_results.txt 2>/dev/null | sort -u | grep -viE "$JUNK_FILTER" | httpx -mc 200,302,403 -silent | anew FINAL_JS_ENDPOINTS.txt > new_js_found.txt

# إذا تم إيجاد ملفات JS جديدة، أرسل تنبيهاً فوراً
if [ -s new_js_found.txt ]; then
    cat new_js_found.txt | notify -id js_discovery
fi

# --- 4. استخراج ومراقبة ملفات JS (الحجم والتغير) ---
print_status "JS Monitoring (New Files & Size Changes)"

# استخدام httpx لجلب حجم الملف (Content-Length) لكل رابط JS متاح (قديم وجديد)
# النتيجة ستكون بصيغة: [https://url.com/file.js] [200] [12345]
httpx -l FINAL_JS_ENDPOINTS.txt -status-code -content-length -silent > js_metadata_now.txt

# المقارنة: anew سيعتبر أي سطر يتغير فيه الحجم سطرًا جديدًا ويرسل به تنبيه
cat js_metadata_now.txt | anew js_history_metadata.txt > js_changes.txt

if [ -s js_changes.txt ]; then
    echo "⚠️ JS Change Detected (Size change or brand new target):"
    cat js_changes.txt | notify -id js_discovery
fi
