import sys

def convert_8bit_to_decimal(binary_string: str) -> int:
    """
    Konverterar en 8-bitars binär sträng till ett decimaltal.
    """
    
    # Validering: Kontrollera att strängen är 8 tecken lång
    if len(binary_string) != 8:
        raise ValueError(f"Fel: Indata måste vara exakt 8 bitar, men var {len(binary_string)} bitar.")
        
    # Validering: Kontrollera att det bara är ettor och nollor
    if not all(c in '01' for c in binary_string):
        raise ValueError(f"Fel: Indata innehåller ogiltiga tecken. Använd endast '0' och '1'.")

    # Konvertera från bas 2 (binärt) till bas 10 (decimalt)
    decimal_value = int(binary_string, 2)
    return decimal_value

if __name__ == "__main__":
    # Kontrollera att ett argument har angetts
    if len(sys.argv) < 2:
        # Skriver ut felmeddelande till stderr (standard error)
        print("Användning: python convert.py <8-bitars binärkod>", file=sys.stderr)
        print("Exempel: python convert.py 01000001", file=sys.stderr)
        sys.exit(1)

    # Hämta den binära koden från kommandoradsargumentet
    input_code = sys.argv[1]

    try:
        # Konvertera
        result = convert_8bit_to_decimal(input_code)
        # Skriv ENDAST ut siffran
        print(result)
    except ValueError as e:
        # Skriv ut felmeddelanden till stderr
        print(e, file=sys.stderr)
        sys.exit(1)
