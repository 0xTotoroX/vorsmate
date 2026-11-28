// [INPUT]: 模拟横向滚轮、精确滚动、手势阶段和惯性序列。
// [OUTPUT]: 方向、单次翻页、连续新手势以及纵向放行回归。
// [POS]: 总览分类切换测试，不向硬件发送事件。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Testing

@testable import Vorsmate

@Suite("分类横向滚动")
struct CategoryScrollTests {
    @Test("触摸板跨过阈值仅切一次，惯性和系统的重复 swipe 不再切换")
    func trackpad() {
        var g = CategoryScrollGesture()
        #expect(g.scroll(x: -9, y: 1, precise: true, phase: .began, momentum: [], at: 0) == 0)
        #expect(g.scroll(x: -16, y: 1, precise: true, phase: .changed, momentum: [], at: 0.02) == 1)
        #expect(g.scroll(x: -30, y: 2, precise: true, phase: .changed, momentum: [], at: 0.04) == 0)
        #expect(g.scroll(x: 0, y: 0, precise: true, phase: .ended, momentum: [], at: 0.1) == 0)
        #expect(g.scroll(x: -45, y: 0, precise: true, phase: [], momentum: .changed, at: 0.2) == 0)
        #expect(g.swipe(x: -1, y: 0, at: 0.22) == 0)
        #expect(g.scroll(x: 25, y: 2, precise: true, phase: .began, momentum: [], at: 0.25) == -1)
        #expect(g.scroll(x: -1, y: 0, precise: false, phase: [], momentum: [], at: 0.26) == 1)
        #expect(g.scroll(x: 1, y: 0, precise: false, phase: [], momentum: [], at: 0.27) == -1)
    }

    @Test("普通鼠标一次横滚一页，斜向和纵向滚动仍交给列表")
    func wheel() {
        var g = CategoryScrollGesture()
        #expect(g.scroll(x: -1, y: 0, precise: false, phase: [], momentum: [], at: 0) == 1)
        #expect(g.scroll(x: -1, y: 0, precise: false, phase: [], momentum: [], at: 0.05) == 0)
        #expect(g.scroll(x: 0, y: 1, precise: false, phase: [], momentum: [], at: 0.06) == nil)
        #expect(g.scroll(x: 1, y: 0, precise: false, phase: [], momentum: [], at: 0.4) == -1)
        #expect(g.scroll(x: 5, y: 5, precise: true, phase: .began, momentum: [], at: 1) == nil)
        #expect(g.scroll(x: 1, y: 18, precise: true, phase: .changed, momentum: [], at: 1.05) == nil)
        #expect(g.scroll(x: 50, y: 3, precise: true, phase: .changed, momentum: [], at: 1.1) == nil)
        #expect(g.scroll(x: 20, y: 12, precise: true, phase: [], momentum: .changed, at: 1.2) == nil)
        #expect(g.swipe(x: 0, y: 1, at: 2) == nil)
        #expect(g.swipe(x: -1, y: 0, at: 3) == 1)
    }
}
