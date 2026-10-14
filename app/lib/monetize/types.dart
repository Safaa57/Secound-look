class PlusProduct {
  PlusProduct(this.id, this.title, this.price);
  final String id, title, price;
}

/// Store product ids. Create subscriptions with exactly these ids in Play Console and App Store Connect.
const plusProductIds = {'secondlook_plus_monthly', 'secondlook_plus_yearly'};
