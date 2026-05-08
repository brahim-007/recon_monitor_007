#!/bin/bash

# --- إعدادات وتنسيق ---
print_status() { echo -e "\e[34m[*] $1...\e[0m"; }

# فلتر للتخلص من القمامة
JUNK_FILTER="(google-analytics|googletag|doubleclick|adsystem|facebook|fbcdn|gtag|tagmanager|hotjar|clarity|png|jpg|css|google|youtube|linkedin|svg|woff|woff2|ttf|otf|ico)"

# فلتر اصطياد الأهداف عالية القيمة
JUICY_FILTER="(api/|graphql|v[0-9]+/|admin|dashboard|user/|config|env|token|oauth|swagger|internal|debug|php)"

DOMAIN="myprotein.com"

# [خطوة حاسمة] تنظيف الملفات
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

# --- [جديد] 2. فحص المنافذ المتقدم (Enhanced Naabu) ---
# تم جعل الفحص أقوى باستخدام مسح كافة المنافذ وفحص الخدمات العميق
print_status "Advanced Port Scanning with Naabu & Nmap"
cat all-domains.txt new_domains.txt | sort -u | sed 's/\/$//' -o subdomains_to_scan.txt
if [ -s new_domains.txt ]; then
    # استخدام -p- لمسح 65535 منفذ + nmap لتعريف الخدمات والإصدارات
    sudo naabu -list subdomains_to_scan.txt -rate 3000 -p - -silent -c 100 -nmap-cli "nmap -sV -sC --open -T4" > port_scan_results.txt
    if [ -s port_scan_results.txt ]; then
        # ضمان إرسال المنافذ الخاصة بالدومين المستهدف فقط
        cat port_scan_results.txt | grep "$DOMAIN" | notify -id ports
    fi
fi

# --- 3. جمع الروابط مع الفلترة الفورية ---
print_status "URL Discovery & Filtering"
# إضافة grep "$DOMAIN" لضمان عدم خروج أي رابط خارج النطاق (مثل NCBI أو Guardian)
cat all-domains.txt | gau --threads 10 | grep "$DOMAIN" | grep -viE "$JUNK_FILTER" | uro > wayback_raw.txt

katana -list all-domains.txt -d 3 -jc -silent | grep "$DOMAIN" | grep -viE "$JUNK_FILTER" > katana_raw.txt

# دمج الروابط وفحص الحية منها
cat wayback_raw.txt katana_raw.txt | sort -u | sed 's/\/$//' | httpx -mc 200,301,302,403,401 -silent | anew all_live_urls.txt > new_urls.txt

if [ -s new_urls.txt ]; then
    grep -Ei "$JUICY_FILTER" new_urls.txt | grep "$DOMAIN" > juicy_urls.txt
    if [ -s juicy_urls.txt ]; then
        cat juicy_urls.txt | notify -id endpoint
    fi
    
    # [تصحيح] فرز روابط 403-401 وإرسالها (ثغرات Broken Access Control)
    cat juicy_urls.txt | httpx -mc 403,401 -silent anew new_403_401.txt # تم تصحيح اسم الملف
    if [ -s new_403_401.txt ]; then
        cat new_403_401.txt | notify -id new_403-401
    fi
fi

# --- 4. استخراج الـ JS وتحديد الجديد منه ---
print_status "Extracting JS Files"
grep -Ei "\.js(\?|$)" all_live_urls.txt | grep "$DOMAIN" | grep -viE "$JUNK_FILTER" > raw_js.txt

# استخدام getJS مع فلترة النطاق
cat all_live_urls.txt | grep "$DOMAIN" | getJS --complete --output getjs_results.txt

cat raw_js.txt getjs_results.txt 2>/dev/null | sort -u | grep "$DOMAIN" | grep -viE "$JUNK_FILTER" | sed 's/\/$//' | httpx -mc 200,302 -silent | anew FINAL_JS_ENDPOINTS.txt > new_js_found.txt

if [ -s new_js_found.txt ]; then
    cat new_js_found.txt | notify -id js_discovery
fi

# --- 6. مراقبة ملفات JS (الحجم والتغير) ---
print_status "JS Monitoring (New Files & Size Changes)"
sed -i 's/\/$//' FINAL_JS_ENDPOINTS.txt 

# تأكيد الفلترة مرة أخرى قبل الفحص
httpx -l FINAL_JS_ENDPOINTS.txt -status-code -content-length -silent | grep "$DOMAIN" > js_metadata_now.txt

cat js_metadata_now.txt | anew js_history_metadata.txt > js_changes.txt

if [ -s js_changes.txt ]; then
    echo "⚠️ JS Change Detected (Size change or new target):"
    cat js_changes.txt | grep "$DOMAIN" | notify -id js_discovery
fi

# --- [جديد] 5. التحليل العميق للجافا سكريبت (jsluice & mantra) ---
# استخراج الأسرار والبرامترات والـ API من الملفات الجديدة
# --- [تعديل] 5. التحليل العميق للجافا سكريبت (Deep Analysis & Secrets) ---
if [ -s new_js_found.txt ] || [ -s js_changes.txt ]; then
    print_status "Deep Analysis: Extracting Endpoints & API Keys"
    
    # 1. استخراج الروابط ونقاط الـ API/GraphQL وحفظها
    # ملاحظة: دمجنا النتائج هنا لترسل مع الأسرار لاحقاً
    cat new_js_found.txt js_changes.txt 2>/dev/null | xargs -I % jsluice urls % | grep "$DOMAIN" | anew js_endpoints_extracted.txt > new_endpoints_found.txt
    
    # 2. استخراج الأسرار باستخدام mantra و jsluice
    cat new_js_found.txt js_changes.txt 2>/dev/null | xargs -I % jsluice secrets % | anew js_secrets.txt > new_secrets_only.txt

    # 3. دمج كل النتائج الجديدة (Endpoints + Secrets) لإرسالها إلى id secrets
    cat new_endpoints_found.txt new_secrets_only.txt | sort -u > all_new_secrets_and_endpoints.txt

    if [ -s all_new_secrets_and_endpoints.txt ]; then
        echo -e "🔥 [New Discovery] Endpoints & Secrets for $DOMAIN:" | notify -id secrets
        cat all_new_secrets_and_endpoints.txt | notify -id secrets
    fi
fi

