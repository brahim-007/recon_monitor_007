#!/bin/bash

# --- إعدادات وتنسيق ---
print_status() { echo -e "\e[34m[*] $1...\e[0m"; }

# فلتر للتخلص من القمامة (موجود مسبقاً)
JUNK_FILTER="(google-analytics|googletag|doubleclick|adsystem|facebook|fbcdn|gtag|tagmanager|hotjar|clarity|png|jpg|css|google|youtube|linkedin|svg|woff|woff2|ttf|otf|ico)"

# [الجديد] فلتر اصطياد الأهداف عالية القيمة (APIs, IDOR Params, Admin Panels, Logic)
JUICY_FILTER="(api/|graphql|v[0-9]+/|admin|dashboard|config|env|php)"

DOMAIN="myprotein.com"

# [خطوة حاسمة] تنظيف الملفات المرجعية قبل البدء لضمان عدم وجود أخطاء سابقة
print_status "Cleaning Database Files"
[ -f all-domains.txt ] && sed -i 's/\/$//' all-domains.txt
[ -f FINAL_JS_ENDPOINTS.txt ] && sed -i 's/\/$//' FINAL_JS_ENDPOINTS.txt
[ -f all_live_urls.txt ] && sed -i 's/\/$//' all_live_urls.txt

# --- 1. مراقبة النطاقات الفرعية ---
print_status "Subdomain Discovery"
subfinder -d $DOMAIN -all -silent | sort -u | httpx -fc 404 -silent | sed 's/\/$//' | anew all-domains.txt > new_domains.txt
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
cat wayback_raw.txt katana_raw.txt | sort -u | sed 's/\/$//' | httpx -mc 200,301,302,403 -silent | anew all_live_urls.txt > new_urls.txt

# [تعديل دقيق]: فلترة الروابط الجديدة وإرسال الإشعارات للروابط الحساسة فقط
if [ -s new_urls.txt ]; then
    print_status "Extracting Juicy Endpoints for Notification"
    # استخراج الروابط التي تطابق الفلتر الحساس فقط
    grep -Ei "$JUICY_FILTER" new_urls.txt > juicy_urls.txt
    
    if [ -s juicy_urls.txt ]; then
        echo "🔥 Juicy Endpoints Found!"
        cat juicy_urls.txt | notify -id endpoint
    else
        echo "No juicy endpoints in this run, keeping quiet."
    fi
fi

# --- 3. استخراج الـ JS وتحديد الجديد منه ---
print_status "Extracting JS Files"
grep -Ei "\.js(\?|$)" all_live_urls.txt | grep -viE "$JUNK_FILTER" > raw_js.txt

# استخدام getJS
cat all_live_urls.txt | getJS --complete --output getjs_results.txt

# التصفية النهائية والمقارنة (هنا يتم تحديث FINAL_JS_ENDPOINTS.txt تلقائياً)
cat raw_js.txt getjs_results.txt 2>/dev/null | sort -u | grep -viE "$JUNK_FILTER" | sed 's/\/$//' | httpx -mc 200,302,403 -silent | anew FINAL_JS_ENDPOINTS.txt > new_js_found.txt

# إذا تم إيجاد ملفات JS جديدة، أرسل تنبيهاً فوراً
if [ -s new_js_found.txt ]; then
    cat new_js_found.txt | notify -id js_discovery
fi

# --- 4. استخراج ومراقبة ملفات JS (الحجم والتغير) ---
print_status "JS Monitoring (New Files & Size Changes)"

# التأكد من أن القائمة المدخلة لـ httpx منظفة أصلاً (خطوة إضافية للأمان)
sed -i 's/\/$//' FINAL_JS_ENDPOINTS.txt 

# [تم الإصلاح]: إنشاء ملف الميتا داتا الحالي قبل تمريره لـ anew
httpx -l FINAL_JS_ENDPOINTS.txt -status-code -content-length -silent > js_metadata_now.txt

# المقارنة: anew سيعتبر أي سطر يتغير فيه الحجم سطرًا جديدًا ويرسل به تنبيه
cat js_metadata_now.txt | anew js_history_metadata.txt > js_changes.txt

if [ -s js_changes.txt ]; then
    echo "⚠️ JS Change Detected (Size change or brand new target):"
    cat js_changes.txt | notify -id js_discovery
fi
