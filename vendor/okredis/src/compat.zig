//! okredis 對不同 Zig 版本的相容層。
//!
//! 這個 vendored okredis 版本原本直接使用 `std.meta.fieldNames(...)`
//! 和 `std.meta.fieldTypes(...)` 來讀取 struct 欄位資訊。
//!
//! 但 Zig 0.17-dev 的標準庫 API 還在變動，不同 snapshot 對
//! `std.meta.fieldTypes` 的支援不完全一致。為了避免每個 parser、
//! serializer、command 檔案都各自寫一份版本判斷，這裡集中包成兩個
//! 小函式：
//!
//! - `fieldNames(T)`：取得 struct 欄位名稱
//! - `fieldTypes(T)`：取得 struct 欄位型別
//!
//! 呼叫端只需要用 `compat.fieldNames(T)` / `compat.fieldTypes(T)`，
//! 不需要知道目前編譯器版本剛好支援哪一種 `std.meta` API。

const std = @import("std");

/// 回傳型別 `T` 的所有欄位名稱。
///
/// `comptime T: type` 的意思是：
/// - `T` 必須在編譯期就確定
/// - 這個函式不是用來處理 runtime value，而是用來處理型別本身
///
/// 回傳型別 `[]const [:0]const u8` 可以拆成兩層看：
/// - `[:0]const u8`：以 `0` 結尾的不可修改字串
/// - `[]const ...`：多個欄位名稱組成的不可修改 slice
///
/// 這裡目前只是薄薄包一層 `std.meta.fieldNames(T)`，主要是讓呼叫端
/// 都透過 `compat` 取欄位資訊，之後 Zig API 再變動時只需要改這個檔案。
pub fn fieldNames(comptime T: type) []const [:0]const u8 {
    return std.meta.fieldNames(T);
}

/// 回傳型別 `T` 的所有欄位型別。
///
/// 例如：
///
/// ```zig
/// const User = struct {
///     id: u64,
///     name: []const u8,
/// };
/// ```
///
/// `fieldTypes(User)` 會在編譯期得到類似：
///
/// ```zig
/// &.{ u64, []const u8 }
/// ```
///
/// okredis 會用這些型別資訊做泛型解析，例如把 Redis 回傳的 map/list
/// 填回使用者指定的 struct。
pub fn fieldTypes(comptime T: type) []const type {
    // 新一點的 Zig 標準庫如果有 `std.meta.fieldTypes`，就直接使用。
    // `@hasDecl` 是編譯期檢查，不會產生 runtime 成本。
    if (comptime @hasDecl(std.meta, "fieldTypes")) {
        return std.meta.fieldTypes(T);
    } else {
        // 舊一點的 Zig 標準庫沒有 `fieldTypes` 時，可以先用
        // `std.meta.fields(T)` 取得完整欄位資訊，再把每個欄位的 `.type`
        // 抽出來組成 `[]const type`。
        return comptime blk: {
            // `field_infos` 的每個元素都包含欄位名稱、型別、預設值等 metadata。
            const field_infos = std.meta.fields(T);
            // 因為欄位數量在編譯期已知，所以可以建立固定長度的 type 陣列。
            var types: [field_infos.len]type = undefined;
            // 同時走訪 `types` 和 `field_infos`：
            // - `field_type` 是輸出陣列裡目前要填的位置
            // - `field_info` 是來源欄位 metadata
            for (&types, field_infos) |*field_type, field_info| {
                // 把來源欄位的型別存進輸出陣列。
                field_type.* = field_info.type;
            }
            // `types` 是 comptime 區塊裡的暫存陣列。
            // 先綁到 `final`，再回傳它的 slice，讓 Zig 把結果固定成
            // 編譯期常數資料供呼叫端使用。
            const final = types;
            break :blk &final;
        };
    }
}
