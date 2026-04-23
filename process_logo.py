from PIL import Image
import numpy as np

# Load the image
img = Image.open('/Users/kochunlong/.gemini/antigravity/brain/393b83a2-2e1b-440b-a066-20065947863e/media__1776904920799.png').convert('RGBA')
data = np.array(img)

# The background is very dark, let's say RGB < 20
r, g, b, a = data.T

# Calculate luminance
luminance = 0.299 * r + 0.587 * g + 0.114 * b

# Normalize luminance to 0-255 range for alpha
# The brightest part should be 255 alpha, the darkest (background) should be 0.
# Background is around luminance 5. Brightest is around 240.
min_lum = np.min(luminance)
max_lum = np.max(luminance)

alpha = (luminance - min_lum) / (max_lum - min_lum) * 255
alpha = np.clip(alpha, 0, 255).astype(np.uint8)

# Make the image pure white, and use the calculated alpha
data[..., 0] = 255
data[..., 1] = 255
data[..., 2] = 255
data[..., 3] = alpha

# Create new image
new_img = Image.fromarray(data)

# Crop to bounding box
bbox = new_img.getbbox()
if bbox:
    new_img = new_img.crop(bbox)

new_img.save('/Users/kochunlong/conductor/workspaces/Nous/new-york/Sources/Nous/Resources/nous_logo_transparent.png')
print("Image processed and saved!")
