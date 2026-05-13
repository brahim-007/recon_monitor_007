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

# --- 2. فحص المنافذ المتقدم ---
print_status "Advanced Port Scanning"
cat all-domains.txt new_domains.txt | sort -u | sed 's/\/$//' > subdomains_to_scan.txt
if [ -s new_domains.txt ]; then
    sudo naabu -list subdomains_to_scan.txt -rate 3000 -p - -silent -c 100 -nmap-cli "nmap -sV -sC --open -T4" > port_scan_results.txt
    # تصحيح ملكية الملف لضمان القدرة على رفعه لاحقاً
    sudo chown runner:docker port_scan_results.txt 2>/dev/null
    if [ -s port_scan_results.txt ]; then
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
    cat juicy_urls.txt | httpx -mc 403,401 -silent | anew new_403-401.txt # تم تصحيح اسم الملف
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


# استخراج الأسرار والبرامترات والـ API من الملفات الجديدة
# --- [تصحيح] 5. التحليل العميق مع تجاوز خطأ 406 ---
if [ -s new_js_found.txt ] || [ -s js_changes.txt ]; then
    print_status "Deep Analysis: Fixing 406 Error & Extracting Data"

    # جلب المحتوى مع ترويسات متصفح حقيقي لتجاوز المنع
    cat new_js_found.txt js_changes.txt 2>/dev/null | sort -u | \
    httpx -silent \
      -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
      -H "Accept: */*" \
      -body > js_bodies_temp.txt

    # الآن نمرر المحتوى النظيف لـ jsluice (لن تظهر أخطاء 406 هنا لأننا جلبنا الملف محلياً)
    
    # 1. استخراج الروابط
    cat js_bodies_temp.txt | jsluice urls | grep "$DOMAIN" | anew js_endpoints_extracted.txt > new_endpoints_found.txt
    
    # 2. استخراج البرامترات
    cat js_bodies_temp.txt | jsluice urls | grep "?" | cut -d '?' -f 2- | tr '&' '\n' | cut -d '=' -f 1 | sort -u | anew js_parameters_extracted.txt > new_params_found.txt
    
    # 3. استخراج الأسرار
    cat js_bodies_temp.txt | jsluice secrets | anew js_secrets.txt > new_secrets_only.txt

    # دمج النتائج للتنبيه
    cat new_endpoints_found.txt new_params_found.txt new_secrets_only.txt 2>/dev/null | sort -u > all_new_discovery.txt

    if [ -s all_new_discovery.txt ]; then
        echo -e "🚀 [Bypassed 406] New Discovery for $DOMAIN" | notify -id secrets
        cat all_new_discovery.txt | notify -id secrets
    fi
    
    rm js_bodies_temp.txt
fi

