//
//  DOPkgManagerPickerViewController.m
//  Dopamine
//
//  Created by tomt000 on 11/02/2024.
//

#import "DOPkgManagerPickerViewController.h"
#import "DOPkgManagerPickerView.h"
#import "DOEnvironmentManager.h"
#import "DOUIManager.h"
#import "DOAppOperationProgress.h"


@interface DOPkgManagerPickerViewController ()
@property (nonatomic) BOOL installationInProgress;
@end

@implementation DOPkgManagerPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    DOPkgManagerPickerView *picker = [[DOPkgManagerPickerView alloc] initWithCallback:^(BOOL success) {
        if (!success || self.installationInProgress) return;
        self.installationInProgress = YES;
        self.view.userInteractionEnabled = NO;
        UIView *progress = DOShowAppOperationProgress(self.navigationController.view ?: self.view);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError *error = [[DOEnvironmentManager sharedManager] reinstallPackageManagers];
            dispatch_async(dispatch_get_main_queue(), ^{
                [progress removeFromSuperview];
                self.installationInProgress = NO;
                self.view.userInteractionEnabled = YES;
                if (error) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DOLocalizedString(@"Button_Reinstall_Package_Managers") message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:DOLocalizedString(@"Button_Close") style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:alert animated:YES completion:nil];
                }
                else [self.navigationController popViewControllerAnimated:YES];
            });
        });
    }];
    picker.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:picker];
    [NSLayoutConstraint activateConstraints:@[
        [picker.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [picker.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [picker.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [picker.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}


@end
