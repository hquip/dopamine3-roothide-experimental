#import <UIKit/UIKit.h>
#import "DOUIManager.h"

static inline UIView *DOShowAppOperationProgress(UIView *host)
{
    UIView *overlay = [[UIView alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.color = [UIColor whiteColor];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.accessibilityLabel = DOLocalizedString(@"Jailbreak_App_Operation_Working");
    [overlay addSubview:spinner];
    UILabel *label = [UILabel new];
    label.text = DOLocalizedString(@"Jailbreak_App_Operation_Working");
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:17];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-15],
        [label.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:16]
    ]];
    [host addSubview:overlay];
    [spinner startAnimating];
    return overlay;
}
