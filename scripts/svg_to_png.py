import fitz

doc = fitz.open("assets/images/aur_bhai_logo.svg")
page = doc.load_page(0)
pix = page.get_pixmap(alpha=True, dpi=300)
pix.save("assets/images/aur_bhai_logo.png")
print("Converted SVG to PNG")
