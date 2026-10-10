#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVFoundation は不正な設定で NSException を投げる。Swift では捕まえられないため、ここで NSError に変換する。
BOOL CSObjCTry(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
