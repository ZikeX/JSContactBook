//
//  ContactManager.m
//  JSContactBook
//
//  Created by Jayesh on 8/2/17.
//  Copyright © 2017 Jayesh. All rights reserved.
//

#import "ContactManager.h"

@implementation ContactManager

/**
 *  @author Jayesh Sojitra
 *
 *  Crates singleton object for Contact Manager Class.
 *
 *  @return Object of ContactManager.
 */
+(ContactManager *)sharedContactManager
{
    static ContactManager *_sharedObj = nil;
    static dispatch_once_t onceInstance;
    dispatch_once(&onceInstance, ^{
        _sharedObj = [[self alloc] init];
    });
    return _sharedObj;
}

- (instancetype)init
{
    self = [super init];
    
    if(self)
    {
        self.store            = [[CNContactStore alloc]init];
        self.arrayContacts    = [[NSMutableArray alloc] init];
        self.keys             = @[CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactImageDataAvailableKey, CNContactImageDataKey, CNContactViewController.descriptorForRequiredKeys, CNContactImageDataKey, CNContactThumbnailImageDataKey];
    }
    
    return self;
}


/**
 *  @author Jayesh Sojitra
 *
 *  Request access to contact book to retrieve or manipulate contacts.
 *
 */
- (void)requestContactManagerWithCompletion:(JSContactManagerCompletion)completion
{
    [self.store requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError * _Nullable error) {
        
        if (granted) {
            completion(YES, nil);
        }
        else
        {
            completion(NO, error);
        }
        
    }];
}

/**
 *  @author Jayesh Sojitra
 *
 *  This method is used to retrieve all contacts there is in the device.
 *
 */
-(void)fetchContactsWithCompletion:(JSContactManagerFetchContactsCompletion)completion
{
    self.arrayContacts = [[NSMutableArray alloc] init];
    
    NSError *error = nil;
    NSArray *containers = [self.store containersMatchingPredicate:nil error:&error];
    
    if (containers.count>0) {
        [containers enumerateObjectsUsingBlock:^(CNContainer *container, NSUInteger idx, BOOL * _Nonnull stop) {
            
            NSError *errorContainer = nil;
            NSPredicate *predicateContactsContainer = [CNContact predicateForContactsInContainerWithIdentifier:container.identifier];
            
            NSArray *arrayContactsInContainer = [self.store unifiedContactsMatchingPredicate:predicateContactsContainer keysToFetch:self.keys error:&errorContainer];
            [self.arrayContacts addObjectsFromArray:arrayContactsInContainer];
            
            NSError *fetchContacts = nil;
            if ([container isEqual:[containers lastObject]]) {
                
                // Synchronise contacts with database in background.
                BOOL cacheContacts = [self cacheContacts:self.arrayContacts error:&fetchContacts];
                if (cacheContacts) {
                    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kIsContactCached];
                    completion(self.arrayContacts,error);
                }
                else
                {
                    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kIsContactCached];
                    completion(nil,error);
                }
            }
            
        }];
    }
    else
    {
        completion(@[],error);
    }
}

/**
 *  @author Jayesh Sojitra
 *
 *  This method is used to update contacts from the application to device.
 *
 */
- (void)updateContact:(CNMutableContact*)mutableContact withCompletion:(JSContactManagerUpdateContactsCompletion)completion
{
    CNSaveRequest *saveRequest = [[CNSaveRequest alloc] init];
    [saveRequest updateContact:mutableContact];
    NSError *error;
    if([self.store executeSaveRequest:saveRequest error:&error]) {
        completion(YES, error);
    }else {
        completion(NO, error);
    }
}

/**
 *  @author Jayesh Sojitra
 *
 *  This method is used to delete from the application to device.
 *
 */
- (void)deleteContact:(CNMutableContact*)mutableContact withCompletion:(JSContactManagerUpdateContactsCompletion)completion
{
    CNSaveRequest *deleteRequest = [[CNSaveRequest alloc] init];
    [deleteRequest deleteContact:mutableContact];
    
    NSError *error;
    if([self.store executeSaveRequest:deleteRequest error:&error]) {
        completion(YES, error);
    }else {
        completion(NO, error);
    }
}

/**
 *  @author Jayesh Sojitra
 *
 *  This method is used to add contact from the application to device.
 *
 */
- (void)addContact:(CNMutableContact*)mutableContact withCompletion:(JSContactManagerUpdateContactsCompletion)completion
{
    CNSaveRequest *request = [[CNSaveRequest alloc] init];
    [request addContact:mutableContact toContainerWithIdentifier:nil];
    NSError *error;
    if([self.store executeSaveRequest:request error:&error]) {
        completion(YES, error);
    }else {
        completion(NO, error);
    }
}

/**
 *  @author Jayesh Sojitra
 *
 *  This method is used to add contact if contact does not exist and if there is any existing contact then it will update into it.
 *
 */
- (void)addOrUpdateContact:(CNMutableContact*)mutableContact withCompletion:(JSContactManagerUpdateContactsCompletion)completion
{
    if (![self checkIfContactExist:mutableContact]) {
        [self addContact:mutableContact withCompletion:^(BOOL success, NSError *error) {
            completion(success, error);
        }];
    }
    else
    {
        [self updateContact:mutableContact withCompletion:^(BOOL success, NSError *error) {
            completion(success, error);
        }];
    }
}

/**
 *  @author Jayesh Sojitra
 *
 *  Check if particular contact exist in the application.
 *
 */
- (BOOL)checkIfContactExist:(CNContact*)contact
{
    NSError *error;
    [self.store unifiedContactWithIdentifier:contact.identifier keysToFetch:self.keys error:&error];
    if (error==nil) {
        return YES;
    }
    return NO;
}

/**
 * Cache Contacts
 */
-(BOOL)cacheContacts:(NSArray<CNContact*>*)contacts error:(NSError * __autoreleasing *)error
{
    NSLog(@"%@",([CoreDataManager sharedCoreData].managedObjectContext!=nil)?@"Core Data Exist":@"Core Data Does Not Exist");
    
    NSManagedObjectContext *taskContext = kAppDelegate.persistentContainer.newBackgroundContext;
    if (!taskContext) {
        return NO;
    }
    
    if (![self importFromContactsArray:contacts usingContext:taskContext error:error]) {
        return NO;
    }
    
    return YES;
}

- (BOOL)importFromContactsArray:(NSArray<CNContact*>*)contacts usingContext:(NSManagedObjectContext *)taskContext
                          error:(NSError * __autoreleasing *)error {
    
    [taskContext performBlockAndWait:^{
        
        // Check if any contact is deleted from contact book.
        
        BOOL isContactCached = [[NSUserDefaults standardUserDefaults] boolForKey:kIsContactCached];
        if (isContactCached) {
            NSMutableArray *arrayIds = [[NSMutableArray alloc] init];
            [contacts enumerateObjectsUsingBlock:^(CNContact * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                [arrayIds addObject:obj.identifier];
            }];
            
            NSArray *arrayContacts = [taskContext getDataForEntity:NSStringFromClass([JSContact class]) Where:@"NONE contactIdntifier IN %@",arrayIds];
            if (arrayContacts.count) {
                NSLog(@"Deleted Records : %@",arrayContacts);
                [arrayContacts enumerateObjectsUsingBlock:^(JSContact *obj, NSUInteger idx, BOOL * _Nonnull stop) {
                    
                    NSInteger count = [taskContext getAllDataForEntity:NSStringFromClass([JSContactHistory class])].count;
                    JSContactHistory *conactEntity = [taskContext insertIntoEntity:NSStringFromClass([JSContactHistory class])];
                    conactEntity.historyId = (int32_t)count+1;
                    conactEntity.contactId = obj.contactIdntifier;
                    conactEntity.operation = kContactOperationDeleted;
                    conactEntity.fieldType = kFieldTypeContact;
                    conactEntity.contactDisplayName = obj.displayName;
                    
                    [taskContext deleteObject:obj];

                }];
            }
        }
        
        for (CNContact *contact in contacts) {
            JSContact *conactEntity = [taskContext insertIntoEntity:NSStringFromClass([JSContact class]) AgainstConditions:@"contactIdntifier = %@",contact.identifier];
            [conactEntity updateFromContact:contact withContext:taskContext];
        }
        
        if ([taskContext hasChanges]) {
            
            if (![taskContext save:error]) {
                return;
            }
            [taskContext reset];
        }
    }];
    
    return *error ? NO : YES;
}

@end
