import base64
import sys
import os

def convert_file_to_base64_string(filepath):
    """
    Öppnar en fil i binärt läge, läser innehållet och
    returnerar det som en Base64-kodad sträng.
    Kastar ett FileNotFoundError om filen inte hittas.
    """
    with open(filepath, 'rb') as binary_file:
        binary_data = binary_file.read()
        base64_encoded_bytes = base64.b64encode(binary_data)
        base64_string = base64_encoded_bytes.decode('utf-8')
        return base64_string

if __name__ == "__main__":
    # Kontrollera att ett filnamn har angetts som argument
    if len(sys.argv) < 2:
        print("Användning: python konvertera.py <sökväg_till_fil>")
        sys.exit(1)

    input_filepath = sys.argv[1]
    # Skapa ett namn för output-filen, t.ex. 'min_fil.p01.b64.txt'
    output_filepath = f"{input_filepath}.b64.txt"

    try:
        # Konvertera filen
        base64_content = convert_file_to_base64_string(input_filepath)

        # Spara resultatet till en ny fil
        with open(output_filepath, 'w') as output_file:
            output_file.write(base64_content)

        print(f"Konvertering klar. Base64-datan har sparats i filen: '{output_filepath}'")

    except FileNotFoundError:
        print(f"Fel: Filen '{input_filepath}' hittades inte.")
        sys.exit(1)
    except Exception as e:
        print(f"Ett oväntat fel inträffade: {e}")
        sys.exit(1)
