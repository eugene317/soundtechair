from PIL import Image, ImageDraw

img = Image.open('/tmp/panel.png').convert('RGBA')
white_bg = Image.new('RGBA', img.size, (255, 255, 255, 255))
composited = Image.alpha_composite(white_bg, img).convert('RGB')

# crop just the right box region with generous margin for close inspection
crop = composited.crop((520, 20, 723, 260))
crop = crop.resize((crop.width * 2, crop.height * 2))
draw = ImageDraw.Draw(crop)

# overlay my current hypothesis (scaled x2, offset by crop origin 520,20)
def to_crop_coords(x, y):
    return ((x - 520) * 2, (y - 20) * 2)

box = (566, 60, 676, 215)
p1 = to_crop_coords(box[0], box[1])
p2 = to_crop_coords(box[2], box[3])
draw.rectangle([p1, p2], outline=(255, 0, 0), width=2)
mid_y = to_crop_coords(0, 137)[1]
draw.line([(p1[0], mid_y), (p2[0], mid_y)], fill=(0, 255, 0), width=2)

crop.save('/tmp/right_box_check.png')
print("saved")
