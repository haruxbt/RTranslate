import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let navy = CGColor(red: 26/255, green: 39/255, blue: 146/255, alpha: 1)
let teal = CGColor(red: 25/255, green: 155/255, blue: 165/255, alpha: 1)
func render(_ size: Int, mono: Bool) throws {
 let c = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 c.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
 if !mono {
  c.addPath(CGPath(roundedRect:CGRect(x:14,y:14,width:996,height:996),cornerWidth:220,cornerHeight:220,transform:nil));c.setFillColor(CGColor(gray:1,alpha:1));c.fillPath()
  c.addPath(CGPath(roundedRect:CGRect(x:14,y:14,width:996,height:996),cornerWidth:220,cornerHeight:220,transform:nil));c.setStrokeColor(CGColor(red:216/255,green:220/255,blue:228/255,alpha:1));c.setLineWidth(14);c.strokePath()
 }
 c.setLineWidth(72);c.setLineCap(.round)
 func wave(_ x:CGFloat,_ y:CGFloat,_ a:CGFloat,_ b:CGFloat,_ d:CGFloat,_ e:CGFloat,_ endX:CGFloat,_ endY:CGFloat,_ color:CGColor){
  c.setStrokeColor(color);c.move(to:CGPoint(x:x,y:y));c.addCurve(to:CGPoint(x:endX,y:endY),control1:CGPoint(x:a,y:b),control2:CGPoint(x:d,y:e));c.strokePath()
 }
 let ink=CGColor(gray:0,alpha:1)
 wave(310,282,177,409,177,615,310,742,mono ? ink:navy)
 wave(380,365,297,446,297,578,380,659,mono ? ink:navy)
 wave(714,282,847,409,847,615,714,742,mono ? ink:teal)
 wave(644,365,727,446,727,578,644,659,mono ? ink:teal)
 func arrow(_ reflected:Bool){
  c.saveGState();if reflected {c.translateBy(x:1024,y:0);c.scaleBy(x:-1,y:1)}
  c.setFillColor(mono ? ink:navy);c.move(to:CGPoint(x:410,y:453));c.addCurve(to:CGPoint(x:439,y:439),control1:CGPoint(x:410,y:435),control2:CGPoint(x:424,y:430));c.addLine(to:CGPoint(x:482,y:497));c.addQuadCurve(to:CGPoint(x:482,y:527),control:CGPoint(x:504,y:512));c.addLine(to:CGPoint(x:439,y:585));c.addCurve(to:CGPoint(x:410,y:571),control1:CGPoint(x:424,y:594),control2:CGPoint(x:410,y:589));c.closePath();c.fillPath();c.restoreGState()
 }
 arrow(false);arrow(true)
 let image=c.makeImage()!,name=mono ? "toolbar-\(size).png":"icon-\(size).png"
 let dest=CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(dest,image,nil);if !CGImageDestinationFinalize(dest){fatalError("PNG failed")}
}
for size in [16,32,48,64,128,256,512,1024] {try render(size,mono:false)}
for size in [16,32,48,64,128] {try render(size,mono:true)}
