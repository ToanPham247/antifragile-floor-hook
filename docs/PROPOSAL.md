# Antifragile Floor — AMM có sàn giá tự nuôi (self-funded price floor)

> **Một AMM mà người bán KHÔNG BAO GIỜ thủng dưới một sàn giá do chính volume của pool nuôi.**
> Mỗi swap trích 1 lát vào **reserve QUOTE**; reserve tạo 1 **buy-wall sàn** mà bất kỳ ai bán cũng chốt được. Sàn **ratchet lên** theo reserve/supply, không bao giờ tụt. "Memecoin có phao cứng, không rug được" — hoàn toàn on-chain, minh bạch.

## 1. Elevator pitch (cho giveaway B)
"The hook I wish existed: a token with an unbreakable, self-funded floor. Every trade quietly funds a reserve; the AMM itself guarantees a redemption price backed by that reserve, so panic sells hit a real wall instead of zero. Downside insurance as a native AMM primitive — the pool literally gets *more* solid the more it's used."

## 2. Novelty — vì sao KHÔNG trùng
- Verify 02/08/2026: catalog v4 có *buyback* và *savings-vault* nhưng **chưa có** hook **cưỡng thực thi một sàn-giá redeemable** ngay trong đường swap (người bán route thẳng vào buy-wall reserve khi giá spot ≤ floor).
- Khác OlympusDAO-style "backing" (đó là tokenomics off-AMM): đây là **primitive cấp AMM**, sàn được hook *enforce* trên mỗi cú bán.
- Chạy trên **aggregate pool-state** → **không dính lỗi danh tính router** của v4 (điểm mạnh so với các hook per-ví).

## 3. Cơ chế
Ký hiệu: token `TKN`, quote `QUOTE`, `R` = reserve QUOTE do hook giữ, `S` = circulating supply TKN.

1. **Nuôi reserve (INCLUSIVE):** mỗi swap hook thu **một charge hook-owned tổng `feeTotalBps` (vd 30bps)** trên quote-side volume; theo fee-policy `effective=max(selected,10bps)` → **đúng 10bps về Programmable** (owner cố định) + **phần dư (`feeTotalBps−10` = 20bps) → cộng vào `R`**. KHÔNG cộng-thêm 0.10% lên trên (đừng biến 30→40bps). Pool LP fee là category riêng (về LP).
2. **Floor price:** `floor = R / S_backed` (backing/token). `S_backed` = supply đang được bảo chứng. Đây là mức QUOTE-per-TKN mà hook cam kết mua lại.
3. **Enforce khi bán:** ở `beforeSwap` chiều **sell TKN→QUOTE**, nếu giá thực thi AMM sẽ **rơi dưới `floor`**, hook **chặn phần dưới sàn** và **thực thi tại `floor`** qua `beforeSwapReturnDelta`: hook nhận TKN của người bán, trả QUOTE từ `R` tại đúng `floor`. Người bán luôn được ≥ floor. 🔒 **Chốt (preflight):** honor LUÔN chừa 1 mẩu **AMM leg nonzero** (`zeroAmmLeg=forbidden`) — chỉ backstop *phần dưới sàn*, KHÔNG thay thế toàn bộ cú swap → tránh bị xếp `customCurve` (review math/audit nặng), vẫn giữ guarantee ≥floor + sink.
4. **Ratchet:** `floor` chỉ được phép **tăng hoặc giữ**; khi reserve/token tăng, floor nhích lên và **không tụt** (lưu `floorHigh`). → cam kết đơn điệu, chống thao túng "bơm rồi rút sàn".
5. **TKN mua tại sàn:** phần TKN hook thu khi honor floor được **burn** hoặc **giữ trong reserve** (tham số) → giảm `S`, tự củng cố floor (vòng phản hồi "antifragile": bán tháo càng nhiều, floor càng vững).

## 4. Tích hợp hook v4
**Permissions bật:** `afterInitialize`, `beforeSwap` + `beforeSwapReturnDelta`, `afterSwap`.

- `beforeSwap` (sell side): so `floor` vs giá thực thi; nếu thủng → return delta để honor tại floor bằng `R`.
- `beforeSwap` (buy side): bình thường; cập nhật kế toán.
- `afterSwap`: thu charge tổng `feeTotalBps` → tách **10bps → owner** + **phần dư → reserve `R`** (inclusive); cập nhật `floorHigh` (chỉ tăng).
- Reserve `R` & TKN thu về giữ dưới dạng **ERC-6909 claims** trong PoolManager (flash-accounting), **không custody mờ ám** — mọi luồng disclose.

## 5. Tích 0.10% protocol fee — INCLUSIVE (🔒 verify preflight)
🔒 Chọn **tổng hook-owned volume charge = `feeTotalBps`** (default 30bps); `effective = max(selected, 10bps)`; **đúng 10 bps → owner cố định `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c`** (sole claim authority, immutable) + **phần dư = project → reserve `R`**. `floorBps` = phần project này (`= feeTotalBps − 10`), **KHÔNG phải khoản cộng-thêm** (cấm biến 30bps thành 40bps). Pool LP fee = category riêng (về LP). Thu qua return-delta **quadrant-dependent** (quote=WETH=currency0 → path before/after/after/before). Permission mask = `0x10cc`.

## 6. Tham số cấu hình
| Param | Ý nghĩa | Default gợi ý |
|-------|---------|---------------|
| `feeTotalBps` | tổng hook-owned charge (≥10; 10→Programmable, dư→reserve) | 30 (0.30%) |
| `floorBps` | phần project → reserve = `feeTotalBps−10` (DERIVED, KHÔNG cộng-thêm) | 20 (0.20%) |
| `zeroAmmLeg` | 🔒 `forbidden` — honor luôn chừa AMM leg nonzero (né customCurve) | forbidden |
| `sinkMode` | TKN honor-floor → `BURN` hoặc `HOLD` | BURN |
| `backedSupplyMode` | `S_backed` = full supply hay chỉ circulating-ex-treasury | circulating |

## 7. Value flows & authorities
- **Reserve custody:** hook giữ `R` (QUOTE) + TKN sink dưới ERC-6909, **giải thích rõ** mục đích (honor floor).
- **Authority:** không admin rút reserve; floor monotonic (chỉ code, không ai chỉnh); tham số immutable sau launch; 10bps → owner cố định.
- **Failure modes:** reserve cạn giữa cú honor lớn → honor **một phần tới hết `R`**, phần dư fill theo AMM (disclose rõ, không hứa suông); floor không bao giờ hứa vượt `R` thực có.

## 8. Threat model (nháp)
- **Bơm-rút sàn:** floor monotonic + tính trên reserve THỰC → không "rút sàn" được.
- **Drain reserve qua honor loop:** honor chỉ ở đúng floor, không tạo lãi vòng; arbitrage giữa floor và AMM tự khép (mua ở AMM rẻ hơn floor là không thể vì floor ≤ giá backing).
- **Reentrancy / delta accounting:** settle trong 1 `unlock`; `beforeSwapReturnDelta` cân đối chính xác BalanceDelta; invariant `R ≥ 0`, `floor ≤ R/S`.
- **Rounding:** fuzz honor tại biên reserve; đảm bảo không rút quá `R`.
- **Grief spam sell nhỏ:** mỗi honor tốn gas người bán; không hại reserve (trả đúng giá trị).

## 9. Vì sao qua reject-filter
Không hidden restriction (floor **có lợi** cho người bán, disclose đầy đủ) · callback `onlyPoolManager` · reserve custody **giải thích rõ** · không privileged arbitrary call · settle kiểm kết quả · self-contained, **không oracle/keeper/upgrade** (floor tính từ state nội bộ, không cần giá ngoài).

## 10. Kế hoạch build 7 ngày
- **D1** `doctor` + `scaffold`; state reserve `R`, `floorHigh`, ERC-6909 claims.
- **D2** `afterSwap`: trích `floorBps` + 0.1% fee + ratchet floor; unit test.
- **D3** `beforeSwap` + `beforeSwapReturnDelta` honor-tại-floor; sink BURN/HOLD.
- **D4** edge: reserve cạn (partial honor), biên rounding; test.
- **D5** fuzz + invariant (`R≥0`, monotonic floor, no-drain); `TEST_PLAN`, `THREAT_MODEL`.
- **D6** `check` → sửa → `package`.
- **D7** `prepare-pr` → nộp PR.

## 11. Rủi ro & open questions
- Chọn `S_backed` (full vs circulating) ảnh hưởng floor — chốt `circulating` cho hợp lý kinh tế.
- `beforeSwapReturnDelta` honor-partial khi reserve mỏng: cần test kỹ kế toán delta.
- Có nên để floor **cũng áp cho mua** (trần?) — KHÔNG, chỉ sàn cho bán, giữ đơn giản v1.
- Xác nhận signed-delta semantics khớp version PoolManager skill pin.
