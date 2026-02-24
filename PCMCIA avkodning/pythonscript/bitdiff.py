#!/usr/bin/env python3
import sys
import os

# ANSI-färgkoder för tydlighet
RÖD = '\033[91m'
GRÖN = '\033[92m'
GUL = '\033[93m'
VIT = '\033[0m'
GRÅ = '\033[90m'
FET = '\033[1m'

def format_byte_info(val):
    """Returnerar en sträng med 'BITS (DECIMAL)'"""
    if val is None:
        return "EOF"
    
    # Skapa bit-sträng (8 bitar)
    bits = f"{val:08b}"
    decimal = f"{val}"
    
    # Färglägg bitarna
    colored_bits = ""
    for b in bits:
        if b == '1': colored_bits += f"1"
        else: colored_bits += f"{GRÅ}0{VIT}"
        
    return f"{colored_bits} ({decimal})"

def compare_single_pair(file1_path, file2_path, filename):
    """Jämför två specifika filer och skriver ut skillnader."""
    try:
        with open(file1_path, 'rb') as f1, open(file2_path, 'rb') as f2:
            data1 = f1.read()
            data2 = f2.read()
    except Exception as e:
        print(f"{RÖD}Kunde inte läsa filerna: {e}{VIT}")
        return

    len1 = len(data1)
    len2 = len(data2)
    
    # Om filerna är binärt identiska, skriv bara det och avsluta snabbt
    if data1 == data2:
        print(f"{GRÖN}[OK] {filename} är identiska.{VIT}")
        return

    # Om skillnader finns, skriv ut header
    print(f"\n{GUL}{'='*60}{VIT}")
    print(f"{FET}JÄMFÖR: {filename}{VIT}")
    print(f"Katalog 1: {os.path.dirname(file1_path)}")
    print(f"Katalog 2: {os.path.dirname(file2_path)}")
    print(f"{GUL}{'='*60}{VIT}")

    max_len = max(len1, len2)
    
    print(f"{'BYTE #':<8} | {'FIL 1 (BITS/DEC)':<20} | {'FIL 2 (BITS/DEC)':<20}")
    print("-" * 60)

    diff_count = 0
    # Visa max 50 fel per fil för att inte svämma över terminalen (valfritt)
    max_errors_to_show = 100 

    for i in range(max_len):
        b1 = data1[i] if i < len1 else None
        b2 = data2[i] if i < len2 else None

        if b1 != b2:
            info1 = format_byte_info(b1)
            info2 = format_byte_info(b2)
            
            print(f"{i:<8} | {info1:<20} | {info2:<20}")
            diff_count += 1
            
            if diff_count >= max_errors_to_show:
                print(f"{RÖD}... för många skillnader, avbryter utskrift för denna fil.{VIT}")
                break

    print("-" * 60)
    print(f"{RÖD}Totalt {diff_count} bytes skiljer sig i {filename}.{VIT}\n")

def process_directories(dir1, dir2):
    if not os.path.isdir(dir1):
        print(f"Fel: '{dir1}' är inte en katalog.")
        return
    if not os.path.isdir(dir2):
        print(f"Fel: '{dir2}' är inte en katalog.")
        return

    # Hämta alla filer (ignorera underkataloger)
    files1 = set(f for f in os.listdir(dir1) if os.path.isfile(os.path.join(dir1, f)))
    files2 = set(f for f in os.listdir(dir2) if os.path.isfile(os.path.join(dir2, f)))

    common_files = sorted(list(files1.intersection(files2)))
    unique_to_1 = files1 - files2
    unique_to_2 = files2 - files1

    print(f"{FET}Startar jämförelse...{VIT}")
    print(f"Katalog A: {dir1}")
    print(f"Katalog B: {dir2}")
    print("-" * 40)

    # 1. Rapportera unika filer (som inte går att jämföra)
    if unique_to_1:
        print(f"{GRÅ}Filer som bara finns i {dir1}:{VIT}")
        for f in unique_to_1: print(f"  - {f}")
    
    if unique_to_2:
        print(f"{GRÅ}Filer som bara finns i {dir2}:{VIT}")
        for f in unique_to_2: print(f"  - {f}")
    
    print("-" * 40)

    # 2. Jämför gemensamma filer
    if not common_files:
        print("Inga gemensamma filnamn hittades att jämföra.")
        return

    for filename in common_files:
        path1 = os.path.join(dir1, filename)
        path2 = os.path.join(dir2, filename)
        compare_single_pair(path1, path2, filename)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Användning: ./script.py <katalog_A> <katalog_B>")
        sys.exit(1)
    
    d1 = sys.argv[1]
    d2 = sys.argv[2]
    
    process_directories(d1, d2)