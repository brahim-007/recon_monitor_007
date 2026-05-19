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


# --- 5. التحليل العميق المصحح (النسخة الاحترافية) ---
if [ -s new_js_found.txt ] || [ -s js_changes.txt ]; then
    print_status "Deep Analysis: Downloading JS Content & Analyzing with jsluice"
    
    # دمج تجميعة الروابط المكتشفة والجديدة في لستة موحدة
    cat new_js_found.txt js_changes.txt 2>/dev/null | sort -u > all_js_to_analyze.txt

    # تهيئة ملفات مؤقتة نظيفة لتجميع مستخرجات هذه الدورة قبل مقارنتها
    > temp_endpoints.txt
    > temp_secrets.txt

    while read -r url; do
        # تخطي الأسطر الفارغة إن وجدت
        [ -z "$url" ] && continue

        echo -e "[*] Fetching content for: $url"
        
        # تحميل كود الجافا سكريبت الفعلي إلى الذاكرة بتوليفة ترويسات متصفح حقيقي لتجاوز الـ WAF
        content=$(curl -s -k -L --max-time 15 \
          -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
          -H "Accept: text/javascript, application/javascript, application/ecmascript, application/x-ecmascript, */*; q=0.01" \
          -H "Accept-Language: en-US,en;q=0.9" \
          "$url")
        
        # الفحص الأول: التأكد من أن السيرفر لم يرجع صفحة حظر HTML (Access Restricted)
        if echo "$content" | grep -qE "(Access Temporarily Restricted|security systems have identified|Cloudflare)"; then
            echo -e "\e[31m[-] Blocked by WAF or Invalid Content for: $url\e[0m"
            continue
        fi

        # الفحص الثاني: التأكد من أن المحتوى المستلم ليس فارغاً
        if [ -z "$content" ]; then
            echo -e "\e[33m[-] Empty response for: $url\e[0m"
            continue
        fi

        # التمرير الفعلي لـ jsluice بعد ضمان وجود كود برمجي حقيقي في الذاكرة
        # 1. استخراج الروابط والمنافذ بشكل خام (Raw)
        echo "$content" | jsluice urls -raw >> temp_endpoints.txt
        
        # 2. استخراج الأسرار الحقيقية النظيفة مع تجاهل أكواد الكومنتات (-g)
        echo "$content" | jsluice secrets -g >> temp_secrets.txt
        
    done < all_js_to_analyze.txt
    
    # تصفية وفلترة المخرجات ومقارنتها بالملفات الأساسية التاريخية باستخدام anew
    if [ -s temp_endpoints.txt ]; then
        # فلترة الروابط لتبقي فقط ما ينتمي لنطاق الهدف المستهدف وتنظيفها
        cat temp_endpoints.txt | grep "$DOMAIN" | sort -u | sed 's/\/$//' | anew js_endpoints_extracted.txt > new_endpoints_found.txt
    fi

    if [ -s temp_secrets.txt ]; then
        cat temp_secrets.txt | sort -u | anew js_secrets.txt > new_secrets_only.txt
    fi

    # تنظيف الملفات المؤقتة من السيرفر فوراً
    rm -f temp_endpoints.txt temp_secrets.txt all_js_to_analyze.txt

    # التنبيه الذكي: نرسل الإشعار فقط إذا ظهر شيء جديد فعلاً لم نكتشفه في الفحوصات السابقة
    if [ -s new_endpoints_found.txt ]; then
        echo -e "🚀 [New Endpoints Found] for $DOMAIN" | notify -id secrets
        cat new_endpoints_found.txt | notify -id secrets
    fi

    if [ -s new_secrets_only.txt ]; then
        echo -e "🔑 [CRITICAL: New Secrets Found] inside JS for $DOMAIN" | notify -id secrets
        cat new_secrets_only.txt | notify -id secrets
    fi
fi
