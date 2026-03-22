import SwiftUI

/// 五维性格雷达图：energy / sociability / independence / curiosity / tenderness
struct PersonalityRadarView: View {
    var energy: Int
    var sociability: Int
    var independence: Int
    var curiosity: Int
    var tenderness: Int

    private let maxValue: CGFloat = 100

    @State private var appearProgress: CGFloat = 0.0

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let radius = side / 2 * 0.8
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            // 网格多层多边形
            for index in 1...4 {
                let path = polygonPath(radius: radius * CGFloat(index) / 4, center: center)
                context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 1)
            }

            // 轴线
            for i in 0..<5 {
                let angle = angleForIndex(i)
                var path = Path()
                path.move(to: center)
                let end = CGPoint(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle)
                )
                path.addLine(to: end)
                context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 1)
            }

            // 雷达区域
            let radar = radarShape(radius: radius, center: center)
            let gradient = Gradient(colors: [
                .accentColor.opacity(0.6),
                .accentColor.opacity(0.2)
            ])
            let shader = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: CGPoint(x: center.x, y: center.y - radius),
                endPoint: CGPoint(x: center.x, y: center.y + radius)
            )
            context.fill(radar, with: shader)
            context.stroke(radar, with: .color(.accentColor), lineWidth: 2)

            // 维度标签
            drawDimensionLabels(context: &context, center: center, radius: radius + 18)
        }
        .scaleEffect(appearProgress, anchor: .center)
        .opacity(appearProgress)
        .onAppear {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.8)) {
                appearProgress = 1.0
            }
        }
        .animation(.easeInOut(duration: 0.35), value: energy)
        .animation(.easeInOut(duration: 0.35), value: sociability)
        .animation(.easeInOut(duration: 0.35), value: independence)
        .animation(.easeInOut(duration: 0.35), value: curiosity)
        .animation(.easeInOut(duration: 0.35), value: tenderness)
    }

    /// 生成指定半径的正五边形路径（以 center 为中心）
    private func polygonPath(radius: CGFloat, center: CGPoint) -> Path {
        var path = Path()
        for i in 0..<5 {
            let angle = angleForIndex(i)
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    /// 根据 DNA 数值生成雷达多边形
    private func radarShape(radius: CGFloat, center: CGPoint) -> Path {
        let values: [CGFloat] = [
            CGFloat(energy),
            CGFloat(sociability),
            CGFloat(independence),
            CGFloat(curiosity),
            CGFloat(tenderness)
        ]

        var path = Path()
        for i in 0..<5 {
            let angle = angleForIndex(i)
            let normalized = max(0, min(values[i], maxValue)) / maxValue
            let r = radius * normalized
            let point = CGPoint(
                x: center.x + r * cos(angle),
                y: center.y + r * sin(angle)
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    /// 绘制维度标签与数值
    private func drawDimensionLabels(context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let entries: [(String, Int)] = [
            ("能量", energy),
            ("社交", sociability),
            ("独立", independence),
            ("好奇", curiosity),
            ("温柔", tenderness)
        ]

        for (index, item) in entries.enumerated() {
            let angle = angleForIndex(index)
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )

            let label = Text(item.0)
                .font(.caption2)
            let value = Text("\(item.1)")
                .font(.caption2.bold())

            context.draw(label, at: CGPoint(x: point.x, y: point.y - 8), anchor: .center)
            context.draw(value, at: CGPoint(x: point.x, y: point.y + 6), anchor: .center)
        }
    }

    /// 计算每个维度对应的角度（以正上方为 0 度，顺时针）
    private func angleForIndex(_ index: Int) -> CGFloat {
        let base = -CGFloat.pi / 2 // 正上方
        let step = 2 * CGFloat.pi / 5
        return base + step * CGFloat(index)
    }
}

struct PersonalityRadarView_Previews: PreviewProvider {
    static var previews: some View {
        PersonalityRadarView(
            energy: 80,
            sociability: 60,
            independence: 40,
            curiosity: 90,
            tenderness: 70
        )
        .frame(width: 240, height: 240)
        .padding()
    }
}
